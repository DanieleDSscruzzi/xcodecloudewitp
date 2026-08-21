/**
 * WITP API — Cloudflare Worker
 * ----------------------------
 * L'unico posto dove vive la chiave Anthropic. L'app non contiene
 * nessuna chiave: manda gli spot + la ricevuta firmata StoreKit 2 (JWS),
 * il Worker verifica l'abbonamento, sceglie il modello e inoltra a Claude.
 *
 * Endpoint:  POST /v1/reason
 * Headers:   x-witp-app:    segreto condiviso con l'app (env WITP_APP_SECRET)
 *            x-witp-device: UUID anonimo del dispositivo (rate limit)
 * Body JSON: { jws: "<Transaction.jwsRepresentation>", context: "...", spots: [...] }
 *
 * Secrets da impostare (mai nel codice):
 *   wrangler secret put ANTHROPIC_API_KEY
 *   wrangler secret put WITP_APP_SECRET
 */

const BUNDLE_ID = "com.danielescruzzi.witp";

const PRODUCT_TIER = {
  "cobianchi.WITP.premium.Claude2":   "premium",
  "cobianchi.WITP.turbo.Claude2":     "turbo",
  "cobianchi.WITP.ultra.Claude2":     "ultra",
  "cobianchi.WITP.ultraplus.Claude2": "ultraplus",
};

// Catena di fallback: se un modello non è disponibile sulla chiave
// (400/404), si scala al successivo. La risposta dichiara SEMPRE
// il modello realmente usato.
const TIER_MODEL = {
  // maxTokens/spotsCap tengono OGNI richiesta sotto ~6 cent anche con Opus
  // (input ≤ ~2K tok, output cappato). monthlyQuota protegge il margine del
  // piano: superata, si scala al modello successivo della catena (mai un
  // errore all'utente); a 3× la quota si chiude il rubinetto.
  premium:   { chain: ["claude-haiku-4-5"],                                       maxTokens: 500, spotsCap: 10, monthlyQuota: 500 },
  turbo:     { chain: ["claude-sonnet-4-6"],                                      maxTokens: 550, spotsCap: 12, monthlyQuota: 450 },
  ultra:     { chain: ["claude-opus-4-8", "claude-sonnet-4-6"],                   maxTokens: 450, spotsCap: 12, monthlyQuota: 240 },
  ultraplus: { chain: ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6"], maxTokens: 450, spotsCap: 14, monthlyQuota: 320 },
};

const TIER_RANK = { free: 0, premium: 1, turbo: 2, ultra: 3, ultraplus: 4 };

const MODEL_LABEL = {
  "claude-haiku-4-5":  "Claude Haiku",
  "claude-sonnet-4-6": "Claude Sonnet",
  "claude-opus-4-8":   "Claude Opus",
  "claude-fable-5":    "Claude Fable",
};

const MAX_SPOTS = 12;
const DAILY_LIMIT = 60; // richieste/dispositivo/giorno (best-effort, in-memory)

// ---------------------------------------------------------------------------

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/v1/redeem" && request.method === "POST") {
      return handleRedeem(request, env);
    }

    if (request.method === "GET" && url.pathname === "/v1/health") {
      return json({ ok: true });
    }
    if (url.pathname === "/v1/support" && request.method === "POST") {
      return handleSupport(request, env);
    }
    if (url.pathname === "/v1/ztl" && request.method === "GET") {
      return handleZTL(request, env);
    }
    if (url.pathname === "/v1/ztl/import" && request.method === "POST") {
      return handleZTLImport(request, env);
    }
    if (url.pathname === "/v1/ztl/list" && request.method === "GET") {
      return handleZTLList(request, env);
    }
    if (url.pathname === "/v1/reports" && request.method === "GET") {
      return handleReports(request, env);
    }
    if (request.method !== "POST" || url.pathname !== "/v1/reason") {
      return json({ error: "not_found" }, 404);
    }

    // 1) Segreto dell'app -----------------------------------------------------
    if (!env.WITP_APP_SECRET || request.headers.get("x-witp-app") !== env.WITP_APP_SECRET) {
      return json({ error: "unauthorized" }, 401);
    }

    // 2) Rate limit best-effort per dispositivo -------------------------------
    const device = (request.headers.get("x-witp-device") || "unknown").slice(0, 64);
    if (!rateLimitOK(device)) return json({ error: "rate_limited" }, 429);

    // 3) Body ------------------------------------------------------------------
    let body;
    try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
    const spots = Array.isArray(body.spots) ? body.spots.slice(0, MAX_SPOTS) : [];
    if (spots.length === 0) return json({ error: "no_spots" }, 400);

    // 4) Abbonamento -----------------------------------------------------------
    let ent = verifyEntitlement(body.jws);

    // Codice sviluppatore: grant firmato — vale come (o più di) un abbonamento.
    if (body.promo) {
      const g = await verifyPromoToken(env, body.promo, request.headers.get("x-witp-device"));
      if (g && (!ent.ok || TIER_RANK[g.tier] > TIER_RANK[ent.tier])) {
        ent = { ok: true, tier: g.tier };
      }
    }

    if (!ent.ok) return json({ error: "subscription_required", detail: ent.reason }, 402);
    const model = TIER_MODEL[ent.tier];

    // 4a) CACHE DEI VERDETTI — è QUI che si abbassano i costi. La stessa
    //     zona (stesse vie, stessi conteggi) richiesta di nuovo entro 10
    //     minuti riusa il verdetto dal KV: ZERO chiamate ad Anthropic.
    //     Le scansioni ripetute (test, utenti concentrati in una zona)
    //     smettono di pagare Claude ogni volta. La chiave è l'impronta
    //     dei parcheggi (nomi+capienze), stabile per la stessa zona.
    let vKey = null;
    if (env.PROMO_KV && Array.isArray(spots) && spots.length) {
      const sig = spots.map(s => `${s.nome}|${s.tipo}|${s.stalli}`).sort().join("~");
      let h = 5381;
      for (let i = 0; i < sig.length; i++) h = ((h * 33) ^ sig.charCodeAt(i)) >>> 0;
      vKey = `verdict:${ent.tier}:${h.toString(36)}`;
      const hit = await env.PROMO_KV.get(vKey);
      if (hit) {
        try { return json({ ...JSON.parse(hit), cachedVerdict: true }); } catch {}
      }
    }

    // 4b) Tetto costi: quota mensile per dispositivo. Oltre quota si scala
    //      al modello più economico della catena (l'utente non vede errori);
    //      a 3× quota, stop. Contatore in KV, scade da solo dopo 62 giorni.
    let chain = model.chain;
    let downgraded = false, quotaLeft = null;
    if (env.PROMO_KV) {
      const ym = new Date().toISOString().slice(0, 7).replace("-", "");
      const usageKey = `use:${device}:${ym}`;
      const used = parseInt((await env.PROMO_KV.get(usageKey)) || "0", 10);
      if (used >= model.monthlyQuota * 3) return json({ error: "quota_esaurita" }, 429);
      if (used >= model.monthlyQuota && chain.length > 1) { chain = chain.slice(1); downgraded = true; }
      quotaLeft = Math.max(0, model.monthlyQuota - used - 1);
      await env.PROMO_KV.put(usageKey, String(used + 1), { expirationTtl: 60 * 60 * 24 * 62 });
    }

    // 5) Claude ----------------------------------------------------------------
    try {
      const { verdict, modelUsed } = await askClaude(env.ANTHROPIC_API_KEY, chain, body.context,
                                                     spots.slice(0, model.spotsCap), model.maxTokens);
      const payload = { ...verdict, model: MODEL_LABEL[modelUsed] || modelUsed, tier: ent.tier,
                        downgraded, quotaLeft };
      // Verdetto in cache per 10 min: la prossima richiesta identica è gratis.
      if (vKey) {
        try { await env.PROMO_KV.put(vKey, JSON.stringify(payload), { expirationTtl: 600 }); } catch {}
      }
      return json(payload);
    } catch (err) {
      return json({ error: "upstream", detail: String(err).slice(0, 200) }, 502);
    }
  },
};

// ---------------------------------------------------------------------------
// Verifica abbonamento (StoreKit 2 JWS)
//
// v1 (beta): decodifica il payload firmato e valida bundle, prodotto,
// scadenza e ambiente. La firma è già verificata sul dispositivo da
// StoreKit 2; qui blocchiamo replay scaduti e prodotti sbagliati.
//
// TODO produzione: verifica server-side completa con l'App Store Server API
// (chiave In-App Purchase da App Store Connect) sostituendo SOLO questa
// funzione — l'interfaccia { ok, tier, reason } resta identica.
// ---------------------------------------------------------------------------
function verifyEntitlement(jws) {
  if (typeof jws !== "string" || jws.split(".").length !== 3) {
    return { ok: false, reason: "missing_jws" };
  }
  let payload;
  try {
    payload = JSON.parse(atob(jws.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  } catch {
    return { ok: false, reason: "bad_jws" };
  }
  if (payload.bundleId !== BUNDLE_ID)        return { ok: false, reason: "bundle" };
  const tier = PRODUCT_TIER[payload.productId];
  if (!tier)                                  return { ok: false, reason: "product" };
  if (!payload.expiresDate || payload.expiresDate < Date.now() - 60_000) {
    return { ok: false, reason: "expired" };
  }
  if (!["Production", "Sandbox", "Xcode"].includes(payload.environment || "Production")) {
    return { ok: false, reason: "environment" };
  }
  return { ok: true, tier };
}

// ---------------------------------------------------------------------------
// Claude
// ---------------------------------------------------------------------------
const SYSTEM_PROMPT = `Sei il layer di ragionamento di WITP (Where Is The Parking), un'app iOS che stima la disponibilità dei parcheggi. Ricevi una lista di parcheggi con la probabilità calcolata da un modello matematico locale (curve orarie, capacità, tipo di zona) e il contesto temporale. Il tuo compito:
1. Raffinare la probabilità (0.0-1.0) di trovare posto ADESSO per ogni parcheggio, partendo dal valore locale e correggendolo con ragionamento di buon senso (orario, giorno, tipo zona, capienza, distanza). Correzioni moderate: resta tipicamente entro ±0.20 dal valore locale, salvo incoerenze evidenti.
2. Scegliere il parcheggio complessivamente MIGLIORE bilanciando probabilità, distanza e tipo (preferisci liberi/a pagamento rispetto a riservati/disabili).
3. Scrivere un riassunto in italiano di massimo 2 frasi, concreto e utile, che dica dove andare e perché (cita il nome della via/parcheggio). Tono calmo, niente esclamazioni.

Rispondi ESCLUSIVAMENTE con JSON valido, senza testo prima o dopo, senza backtick, con questo schema esatto:
{"summary":"...","best_id":"uuid oppure null","spots":[{"id":"uuid","probability":0.0,"reason":"max 90 caratteri in italiano"}]}
Includi in "spots" TUTTI gli id ricevuti, nessuno escluso.`;

async function askClaude(apiKey, chain, context, spots, maxTokens = 600) {
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY non impostata");

  const items = spots.map(s => ({
    id: String(s.id || ""),
    nome: String(s.nome || s.name || "Parcheggio").slice(0, 80),
    tipo: String(s.tipo || ""),
    stalli: Number(s.stalli || 0),
    distanza_m: Number(s.distanza_m || 0),
    probabilita_locale: Number(s.probabilita_locale || 0),
    motivi_locali: Array.isArray(s.motivi_locali) ? s.motivi_locali.slice(0, 3) : [],
  }));

  let res = null, modelUsed = null;
  for (const modelId of chain) {
    res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      signal: AbortSignal.timeout(25_000),
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: modelId,
        max_tokens: maxTokens,
        // Prompt caching sul system: le richieste successive pagano ~10%
        // dei token di sistema. Con Opus: ~6 cent a richiesta, poi ~5.
        system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
        messages: [{
          role: "user",
          content: `Adesso è: ${String(context || "").slice(0, 120)}.\nParcheggi trovati (JSON):\n${JSON.stringify(items, null, 2)}`,
        }],
      }),
    });
    if (res.ok) { modelUsed = modelId; break; }
    if (![400, 404].includes(res.status)) throw new Error(`anthropic ${res.status}`);
    // modello non disponibile sulla chiave → prova il prossimo della catena
  }
  if (!modelUsed) throw new Error(`anthropic ${res ? res.status : "no_model"}`);
  const data = await res.json();
  let text = (data.content || []).find(b => b.type === "text")?.text || "";
  text = text.replace(/```json|```/g, "").trim();
  const s = text.indexOf("{"), e = text.lastIndexOf("}");
  if (s === -1 || e === -1) throw new Error("no_json");
  const v = JSON.parse(text.slice(s, e + 1));

  const clean = (Array.isArray(v.spots) ? v.spots : []).map(a => ({
    id: String(a.id || ""),
    probability: Math.max(0.02, Math.min(0.99, Number(a.probability))),
    reason: String(a.reason || "").slice(0, 120),
  })).filter(a => a.id);
  if (clean.length === 0) throw new Error("empty_verdict");

  return {
    modelUsed,
    verdict: {
      summary: String(v.summary || "").slice(0, 300),
      best_id: v.best_id ? String(v.best_id) : null,
      spots: clean,
    },
  };
}

// ---------------------------------------------------------------------------
// Rate limit in-memory (per isolate — best effort; per limiti duri usare
// Cloudflare Rate Limiting Rules o KV/Durable Objects).
// ---------------------------------------------------------------------------
const bucket = new Map();
function rateLimitOK(device) {
  const day = new Date().toISOString().slice(0, 10);
  const key = `${day}:${device}`;
  const n = (bucket.get(key) || 0) + 1;
  bucket.set(key, n);
  if (bucket.size > 10_000) bucket.clear();
  return n <= DAILY_LIMIT;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ═══ Codici sviluppatore: Ultra+ 2 mesi, monouso per dispositivo ═══
// Codici derivati da WITP_PROMO_SECRET (HMAC): il server li riconosce
// senza doverli memorizzare. KV registra SOLO le redenzioni.

const PROMO_COUNT = 10;
const PROMO_DAYS = 60;

async function hmacRaw(secret, msg) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)));
}

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
function b32(bytes, len) {
  let bits = 0, val = 0, out = "";
  for (const b of bytes) {
    val = (val << 8) | b; bits += 8;
    while (bits >= 5) {
      out += B32[(val >>> (bits - 5)) & 31]; bits -= 5;
      if (out.length >= len) return out;
    }
  }
  return out;
}

async function expectedCode(secret, i) {
  const mac = await hmacRaw(secret, `witp-dev-${String(i).padStart(2, "0")}`);
  const raw = b32(mac, 20);
  return "WITP-DEV-" + [raw.slice(0, 5), raw.slice(5, 10), raw.slice(10, 15), raw.slice(15, 20)].join("-");
}

async function signGrant(secret, payload) {
  const body = btoa(JSON.stringify(payload)).replaceAll("=", "");
  const mac = await hmacRaw(secret, body);
  return body + "." + b32(mac, 32);
}

async function verifyPromoToken(env, token, device) {
  try {
    if (!env.WITP_PROMO_SECRET) return null;
    const [body, sig] = String(token).split(".");
    const mac = await hmacRaw(env.WITP_PROMO_SECRET, body);
    if (b32(mac, 32) !== sig) return null;
    const p = JSON.parse(atob(body));
    if (p.d !== device) return null;
    if (Date.now() > p.e) return null;
    return { tier: p.t, expiresAt: p.e };
  } catch { return null; }
}

async function handleRedeem(request, env) {
  if (request.headers.get("x-witp-app") !== env.WITP_APP_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  const device = request.headers.get("x-witp-device");
  if (!device) return json({ error: "no_device" }, 400);
  if (!env.WITP_PROMO_SECRET) return json({ error: "promo_non_configurato" }, 503);
  if (!env.PROMO_KV) return json({ error: "kv_non_configurato", detail: "wrangler kv namespace create witp_promo" }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
  const code = String(body.code || "").trim().toUpperCase();
  if (!code.startsWith("WITP-DEV-")) return json({ error: "codice_non_valido" }, 400);

  let valid = false;
  for (let i = 1; i <= PROMO_COUNT; i++) {
    if (code === await expectedCode(env.WITP_PROMO_SECRET, i)) { valid = true; break; }
  }
  if (!valid) return json({ error: "codice_non_valido" }, 400);

  const key = "promo:" + code;
  const prev = await env.PROMO_KV.get(key, "json");
  if (prev && prev.device !== device) {
    return json({ error: "codice_gia_usato" }, 409);
  }

  const expiresAt = prev ? prev.expiresAt : Date.now() + PROMO_DAYS * 24 * 3600 * 1000;
  if (!prev) {
    await env.PROMO_KV.put(key, JSON.stringify({ device, expiresAt, redeemedAt: Date.now() }));
  }
  const token = await signGrant(env.WITP_PROMO_SECRET, { d: device, t: "ultraplus", e: expiresAt });
  return json({ token, tier: "ultraplus", expiresAt });
}


/* ═══════════════════ WITP CARE — assistenza con Claude ═══════════════════ */

const SUPPORT_PROMPT = `Sei WITP Care, l'assistenza ufficiale di WITP — Where Is The Parking, l'app iOS di By D.S. (Daniele Scruzzi) che trova parcheggio con l'AI.

COSA SAI DELL'APP:
- Motore WDSL+: cerca parcheggi da OpenStreetMap e Apple Maps — stalli disegnati sulla mappa (blu = a pagamento/strisce blu, bianco = libero, giallo = residenti/clienti, blu scuro = disabili), pillole "P" per strutture senza geometria. La risposta arriva entro il budget del piano; la mappa si completa nei secondi successivi man mano che le fonti rispondono (normale, non è un difetto). La stima di disponibilità (%) è calcolata al momento; le zone già scansionate da altri utenti arrivano all'istante dalla memoria condivisa.
- Il verdetto "miglior parcheggio" lo dà Claude (Anthropic): Haiku 4.5 su Premium, Sonnet 4.6 su Turbo, Opus 4.8 su Ultra, Fable 5 su Ultra+ (che ragiona anche on-device sul Neural Engine). Sul Free decide il motore locale.
- PIANI (settimana/mese/anno): Free gratis (raggio 400 m, risposta 20 s) · Premium 1,99/6,99/69,99 € (1 km, 10 s) · Turbo 3,99/12,99/129,99 € (1,5 km, 5 s, priorità) · Ultra 5,99/19,99/199,99 € (2 km, 3 s) · Ultra+ 13,99/49,99/499,99 € (2,5 km, 1 s). Rinnovo automatico gestito da Apple; disdetta da Impostazioni → [nome] → Abbonamenti; rimborsi solo via Apple su reportaproblem.apple.com. Ripristino: bottone "Ripristina acquisti" nel paywall.
- NAVIGAZIONE: WITP non ha un navigatore proprio, e non serve — il bottone "Portami lì" apre le indicazioni in Apple Maps con il parcheggio già impostato come destinazione. Spiegalo come una scelta (usa il navigatore che l'utente già conosce), mai come una mancanza: non dire "nessun navigatore".
- RICERCA PER INDIRIZZO: l'icona con la lente in alto permette di cercare parcheggi in una zona diversa da dove ci si trova — utile per sapere dove fermarsi prima di partire.
- Funzioni: sosta con Live Activity e promemoria, comandi Siri, condivisione del posto via Apple Maps, 30+ lingue (Profilo → Lingua), codici sviluppatore riscattabili in Profilo.
- PROBLEMI COMUNI: mappa con poche strisce → attendere il completamento (secondi) o zona poco mappata su OpenStreetMap; abbonamento non riconosciuto → "Ripristina acquisti"; niente verdetto Claude → connessione o server momentaneamente giù (il motore locale risponde comunque).
- Link: privacy https://www.whereistheparking.com/support#privacy · termini https://www.whereistheparking.com/support#terms · email info@whereistheparking.com

REGOLE:
- Rispondi nella lingua dell'utente, breve e concreto (max ~120 parole), onesto: se non sai, dillo e indirizza all'email.
- Mai inventare funzioni, prezzi o promesse. Mai sconti non esistenti.
- Se l'utente segnala un bug, un malfunzionamento o propone un'idea, compila il campo "report" così lo sviluppatore la riceve per il prossimo aggiornamento — e diglielo.

FORMATO: rispondi SOLO con JSON valido, senza backtick:
{"reply":"...","report":null}
oppure {"reply":"...","report":{"tipo":"bug|idea|altro","sintesi":"max 140 caratteri"}}`;

const SUPPORT_DAILY = { free: 5, premium: 20, turbo: 25, ultra: 30, ultraplus: 50, ultraPlus: 50 };

async function handleSupport(request, env) {
  if (!env.WITP_APP_SECRET || request.headers.get("x-witp-app") !== env.WITP_APP_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  const device = request.headers.get("x-witp-device") || "anon";
  let body;
  try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }

  const tier = String(body.tier || "free").toLowerCase();
  const limit = SUPPORT_DAILY[tier] ?? 5;

  // Tetto giornaliero per dispositivo (Sonnet ≈ 1 cent/messaggio).
  if (env.PROMO_KV) {
    const day = new Date().toISOString().slice(0, 10).replaceAll("-", "");
    const k = `sup:${device}:${day}`;
    const used = parseInt((await env.PROMO_KV.get(k)) || "0", 10);
    if (used >= limit) return json({ error: "limit" }, 429);
    await env.PROMO_KV.put(k, String(used + 1), { expirationTtl: 60 * 60 * 26 });
  }

  // Sanifica la conversazione: max 12 turni, 600 caratteri l'uno.
  const msgs = (Array.isArray(body.messages) ? body.messages : [])
    .slice(-12)
    .map(m => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: String(m.content || "").slice(0, 600),
    }))
    .filter(m => m.content.length);
  if (!msgs.length || msgs[msgs.length - 1].role !== "user") {
    return json({ error: "no_message" }, 400);
  }

  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-6",
        max_tokens: 550,
        system: [{ type: "text", text: SUPPORT_PROMPT, cache_control: { type: "ephemeral" } }],
        messages: msgs,
      }),
    });
    if (!res.ok) return json({ error: "upstream", status: res.status }, 502);
    const data = await res.json();
    const text = (data.content || []).filter(b => b.type === "text").map(b => b.text).join("\n");
    let parsed;
    try {
      parsed = JSON.parse(text.replace(/```json|```/g, "").trim());
    } catch {
      parsed = { reply: text.trim(), report: null };
    }
    const reply = String(parsed.reply || "").trim() || "Scrivimi pure la tua domanda su WITP.";

    // Segnalazione → archivio per lo sviluppatore (180 giorni).
    let reportSaved = false;
    if (parsed.report && parsed.report.sintesi && env.PROMO_KV) {
      const key = `report:${Date.now()}:${device.slice(0, 8)}`;
      await env.PROMO_KV.put(key, JSON.stringify({
        quando: new Date().toISOString(),
        tier,
        tipo: String(parsed.report.tipo || "altro").slice(0, 12),
        sintesi: String(parsed.report.sintesi).slice(0, 140),
      }), { expirationTtl: 60 * 60 * 24 * 180 });
      reportSaved = true;
    }
    return json({ reply, reportSaved });
  } catch {
    return json({ error: "network" }, 502);
  }
}

/* Le segnalazioni raccolte, solo per lo sviluppatore (header x-witp-admin). */
async function handleReports(request, env) {
  if (!env.WITP_APP_SECRET || request.headers.get("x-witp-admin") !== env.WITP_APP_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!env.PROMO_KV) return json({ reports: [] });
  const listing = await env.PROMO_KV.list({ prefix: "report:", limit: 200 });
  const reports = await Promise.all(
    listing.keys.map(async k => {
      const v = await env.PROMO_KV.get(k.name);
      try { return { key: k.name, ...JSON.parse(v) }; } catch { return { key: k.name }; }
    })
  );
  reports.sort((a, b) => (b.key > a.key ? 1 : -1));
  return json({ totale: reports.length, reports });
}

/* ═══════════════════ ZTL — dataset curato da fonti ufficiali ═══════════════════
 *
 * Perché non OpenStreetMap: le ZTL italiane su OSM sono mappate in modo
 * incompleto (poche decine di città su ~350) e a volte con poligoni che
 * coprono un intero comune (es. "Area B" di Milano), che generano falsi
 * allarmi. I Comuni invece pubblicano il dato ufficiale — perimetro,
 * orari, varchi — sui propri portali open data.
 *
 * Qui le zone vivono in KV, importate una città alla volta da GeoJSON
 * ufficiale. Nessuna coordinata inventata: entra solo ciò che è stato
 * scaricato da una fonte pubblica e verificato.
 *
 * Chiave KV:  ztl:<citta-slug>
 * Valore:     { citta, fonte, aggiornato, zone: [ {nome, orari, poligono} ] }
 */

/** Bounding box di un poligono, per il filtro veloce per distanza. */
function bboxOf(poly) {
  let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
  for (const [lon, lat] of poly) {
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lon < minLon) minLon = lon;
    if (lon > maxLon) maxLon = lon;
  }
  return { minLat, maxLat, minLon, maxLon };
}

function metersBetween(aLat, aLon, bLat, bLon) {
  const mLat = 111320, mLon = 111320 * Math.cos((aLat * Math.PI) / 180);
  const dy = (bLat - aLat) * mLat, dx = (bLon - aLon) * mLon;
  return Math.sqrt(dx * dx + dy * dy);
}

/**
 * Stato di una ZTL ADESSO, nel fuso orario italiano.
 * Ritorna null se oggi non è né attiva né in procinto di attivarsi:
 * quella zona non viene proprio inviata all'app (meno rumore in mappa).
 *
 * Formati orari accettati (sintassi opening_hours):
 *   "24/7"
 *   "Mo-Fr 07:30-19:30"
 *   "Mo-Sa 08:00-12:00,14:00-18:00"
 *   più regole separate da ";"
 */
function ztlStateNow(hours, now = new Date()) {
  if (!hours || !String(hours).trim()) return { stato: "attiva", fino: null };
  const raw = String(hours).trim();
  if (raw === "24/7") return { stato: "attiva", fino: null };

  // Ora locale italiana, indipendente dal fuso del server Cloudflare
  const it = new Date(now.toLocaleString("en-US", { timeZone: "Europe/Rome" }));
  const wd = (it.getDay() + 6) % 7;              // Mo=0 … Su=6
  const mins = it.getHours() * 60 + it.getMinutes();
  const dayNames = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];

  const spans = [];
  for (const rule of raw.split(";")) {
    const r = rule.trim();
    if (!r || r.startsWith("PH")) continue;
    const firstDigit = r.search(/\d/);
    let dayPart = "", timePart = r;
    if (firstDigit > 0) {
      dayPart = r.slice(0, firstDigit).trim();
      timePart = r.slice(firstDigit).trim();
    }
    let dayMatch = dayPart === "";
    if (!dayMatch) {
      for (const chunk of dayPart.split(",")) {
        const c = chunk.trim();
        if (c.includes("-")) {
          const [a, b] = c.split("-").map(x => dayNames.indexOf(x.trim()));
          if (a >= 0 && b >= 0) {
            if (a <= b ? wd >= a && wd <= b : wd >= a || wd <= b) dayMatch = true;
          }
        } else if (dayNames.indexOf(c) === wd) dayMatch = true;
      }
    }
    if (!dayMatch) continue;
    if (!timePart) { spans.push([0, 1440]); continue; }
    for (const span of timePart.split(",")) {
      const parts = span.trim().split("-");
      if (parts.length !== 2) continue;
      const toMin = t => {
        const hm = t.trim().split(":").map(Number);
        return hm.length === 2 && !isNaN(hm[0]) && !isNaN(hm[1]) ? hm[0] * 60 + hm[1] : null;
      };
      const a = toMin(parts[0]), b = toMin(parts[1]);
      if (a !== null && b !== null) spans.push([a, b]);
    }
  }
  if (!spans.length) return null;                 // oggi mai attiva

  for (const [a, b] of spans) {
    const inside = a <= b ? mins >= a && mins <= b : mins >= a || mins <= b;
    if (inside) return { stato: "attiva", fino: b };
  }
  const next = spans.map(s => s[0]).filter(x => x > mins).sort((x, y) => x - y)[0];
  if (next !== undefined && next - mins <= 30) return { stato: "imminente", alle: next };
  return null;                                    // né attiva né imminente
}

/**
 * GET /v1/ztl?lat=..&lon=..&r=1500
 *
 * AUTOMATICO OVUNQUE: interroga OpenStreetMap in diretta per la zona
 * richiesta — Torino, Parigi, Verbania, Genova o qualsiasi altro posto,
 * senza che nessuno debba caricare quella città a mano.
 *
 * Il filtro di qualità sta QUI (lato server) e non nell'app, così posso
 * correggerlo senza pubblicare un aggiornamento su App Store.
 *
 * Se per quella città esiste un dato CURATO (importato da portale
 * comunale ufficiale), quello ha la precedenza su OSM.
 *
 * Cache per riquadro geografico (~1 km) in KV per 12 ore: gli utenti
 * nella stessa zona non interrogano Overpass una seconda volta.
 */
async function handleZTL(request, env) {
  if (!env.WITP_APP_SECRET || request.headers.get("x-witp-app") !== env.WITP_APP_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  const url = new URL(request.url);
  const lat = parseFloat(url.searchParams.get("lat"));
  const lon = parseFloat(url.searchParams.get("lon"));
  const radius = Math.min(parseFloat(url.searchParams.get("r")) || 1500, 5000);
  if (isNaN(lat) || isNaN(lon)) return json({ error: "bad_coords" }, 400);

  const now = new Date();
  let zones = [];

  // 1) Dato curato: se qualcuno ha importato questa città da fonte
  //    ufficiale, vince su OSM (più preciso, orari verificati).
  if (env.PROMO_KV) {
    const curated = await curatedNear(env, lat, lon, radius);
    zones = curated;
  }

  // 2) Altrimenti OSM in automatico, con cache per riquadro.
  if (!zones.length) {
    zones = await osmZTL(env, lat, lon, radius);
  }

  // 3) Stato calcolato ADESSO: solo attive o imminenti escono da qui.
  const out = [];
  for (const z of zones) {
    const state = ztlStateNow(z.orari, now);
    if (!state) continue;
    out.push({
      nome: z.nome, citta: z.citta || "", fonte: z.fonte || "OpenStreetMap",
      orari: z.orari || null, poligono: z.poligono, ...state
    });
    if (out.length >= 20) break;
  }
  return json({ zones: out, aggiornato: now.toISOString() });
}

/** Zone curate (importate da portali comunali) vicine al punto. */
async function curatedNear(env, lat, lon, radius) {
  const listing = await env.PROMO_KV.list({ prefix: "ztl:", limit: 200 });
  const found = [];
  for (const key of listing.keys) {
    const raw = await env.PROMO_KV.get(key.name);
    if (!raw) continue;
    let city;
    try { city = JSON.parse(raw); } catch { continue; }
    for (const zone of city.zone || []) {
      const bb = zone.bbox || bboxOf(zone.poligono);
      const cLat = (bb.minLat + bb.maxLat) / 2, cLon = (bb.minLon + bb.maxLon) / 2;
      const half = metersBetween(bb.minLat, bb.minLon, bb.maxLat, bb.maxLon) / 2;
      if (metersBetween(lat, lon, cLat, cLon) > radius + half) continue;
      found.push({ ...zone, citta: city.citta, fonte: city.fonte });
    }
  }
  return found;
}

/**
 * ZTL da OpenStreetMap, con i filtri di qualità che evitano i falsi
 * allarmi visti sul campo:
 *
 *  - SOLO boundary=limited_traffic_zone. Le low_emission_zone sono
 *    un'altra cosa e coprono interi comuni (era il caso "tutta la
 *    città è ZTL").
 *  - Niente admin_level: un confine amministrativo taggato per errore
 *    come ZTL non è una ZTL.
 *  - Serve un nome o un orario: le geometrie anonime e senza regole
 *    sono quasi sempre abbozzi incompleti.
 *  - Dimensione plausibile: da 100 m a 6 km di diagonale. Sotto è un
 *    errore di digitazione, sopra è un'intera città (es. "Area B" di
 *    Milano, che non è una ZTL da centro storico).
 */
async function osmZTL(env, lat, lon, radius) {
  // Cache per riquadro ~1 km: chi cerca vicino riusa la stessa risposta.
  const key = `ztlosm:${lat.toFixed(2)}:${lon.toFixed(2)}:${Math.round(radius / 500)}`;
  if (env.PROMO_KV) {
    const hit = await env.PROMO_KV.get(key);
    if (hit) { try { return JSON.parse(hit); } catch {} }
  }

  const r = Math.round(radius);
  const query = `[out:json][timeout:12];
(
  way["boundary"="limited_traffic_zone"](around:${r},${lat},${lon});
  relation["boundary"="limited_traffic_zone"](around:${r},${lat},${lon});
);
out geom qt 60;`;

  const mirrors = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter"
  ];

  let elements = null;
  for (const mirror of mirrors) {
    try {
      const res = await fetch(mirror, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "data=" + encodeURIComponent(query)
      });
      if (!res.ok) continue;
      const data = await res.json();
      if (Array.isArray(data.elements)) { elements = data.elements; break; }
    } catch { /* mirror successivo */ }
  }
  if (!elements) return [];

  const zones = [];
  for (const el of elements) {
    const tags = el.tags || {};
    if (tags.admin_level) continue;                       // confine, non ZTL
    const nome = tags.name || null;
    const orari = tags.opening_hours || tags.hours || null;
    if (!nome && !orari) continue;                        // abbozzo incompleto

    // Geometria: way semplice o relazione multipoligono
    let ring = [];
    if (Array.isArray(el.geometry)) {
      ring = el.geometry.map(p => [p.lon, p.lat]);
    } else if (Array.isArray(el.members)) {
      let best = [];
      for (const m of el.members) {
        if ((m.role || "outer") !== "outer" || !Array.isArray(m.geometry)) continue;
        const rg = m.geometry.map(p => [p.lon, p.lat]);
        if (rg.length > best.length) best = rg;
      }
      ring = best;
    }
    if (ring.length < 4) continue;

    // Sanità dimensionale
    const bb = bboxOf(ring);
    const diag = metersBetween(bb.minLat, bb.minLon, bb.maxLat, bb.maxLon);
    if (diag < 100 || diag > 6000) continue;

    // Alleggerimento: max 200 punti
    const step = Math.max(1, Math.floor(ring.length / 200));
    const poligono = ring.filter((_, i) => i % step === 0)
                         .map(([x, y]) => [Number(x.toFixed(6)), Number(y.toFixed(6))]);

    zones.push({
      nome: nome || "ZTL",
      orari,                       // null = nessun orario noto → sempre attiva (prudenza)
      poligono,
      bbox: bboxOf(poligono),
      fonte: "OpenStreetMap"
    });
    if (zones.length >= 25) break;
  }

  if (env.PROMO_KV) {
    // 12 ore: i confini cambiano di rado, lo STATO viene comunque
    // ricalcolato a ogni richiesta sull'ora reale.
    await env.PROMO_KV.put(key, JSON.stringify(zones), { expirationTtl: 43200 });
  }
  return zones;
}

/**
 * POST /v1/ztl/import — carica una città da GeoJSON ufficiale.
 * Header: x-witp-admin: <APP_SECRET>
 * Body:   { citta, fonte, orariDefault, geojson }
 *
 * Accetta un FeatureCollection GeoJSON scaricato dal portale open data
 * del Comune. Legge Polygon e MultiPolygon; gli orari si prendono dalle
 * proprietà della feature (campi "orari"/"opening_hours"/"ORARIO") oppure
 * da orariDefault se la feature non li porta.
 */
async function handleZTLImport(request, env) {
  if (!env.WITP_APP_SECRET || request.headers.get("x-witp-admin") !== env.WITP_APP_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!env.PROMO_KV) return json({ error: "kv_non_configurato" }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
  const citta = String(body.citta || "").trim();
  if (!citta) return json({ error: "citta_mancante" }, 400);
  const fonte = String(body.fonte || "").trim() || "portale open data comunale";
  const orariDefault = body.orariDefault ? String(body.orariDefault) : null;
  const gj = body.geojson;
  if (!gj || !Array.isArray(gj.features)) return json({ error: "geojson_non_valido" }, 400);

  const zone = [];
  for (const f of gj.features) {
    const g = f.geometry;
    if (!g) continue;
    const props = f.properties || {};
    const nome = String(
      props.nome || props.NOME || props.name || props.DESCRIZIONE || citta
    ).slice(0, 60);
    const orari = String(
      props.orari || props.ORARIO || props.opening_hours || props.ORARI || orariDefault || ""
    ).trim() || null;

    const rings = [];
    if (g.type === "Polygon") rings.push(g.coordinates[0]);
    else if (g.type === "MultiPolygon") for (const poly of g.coordinates) rings.push(poly[0]);
    else continue;

    for (const ring of rings) {
      if (!Array.isArray(ring) || ring.length < 4) continue;
      // Semplificazione: max 200 punti per poligono (payload leggero)
      const step = Math.max(1, Math.floor(ring.length / 200));
      const poligono = ring.filter((_, i) => i % step === 0)
                           .map(([lon, lat]) => [Number(lon.toFixed(6)), Number(lat.toFixed(6))]);
      if (poligono.length < 4) continue;
      zone.push({ nome, orari, poligono, bbox: bboxOf(poligono) });
    }
  }
  if (!zone.length) return json({ error: "nessuna_zona_valida" }, 400);

  const slug = citta.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
                    .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const record = { citta, fonte, aggiornato: new Date().toISOString(), zone };
  await env.PROMO_KV.put(`ztl:${slug}`, JSON.stringify(record));
  return json({ ok: true, citta, slug, zoneImportate: zone.length });
}

/** GET /v1/ztl/list — che città sono caricate (per te, non per l'app). */
async function handleZTLList(request, env) {
  if (!env.WITP_APP_SECRET || request.headers.get("x-witp-admin") !== env.WITP_APP_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!env.PROMO_KV) return json({ citta: [] });
  const listing = await env.PROMO_KV.list({ prefix: "ztl:", limit: 200 });
  const citta = [];
  for (const k of listing.keys) {
    const raw = await env.PROMO_KV.get(k.name);
    try {
      const c = JSON.parse(raw);
      citta.push({ citta: c.citta, zone: (c.zone || []).length, fonte: c.fonte, aggiornato: c.aggiornato });
    } catch {}
  }
  return json({ totale: citta.length, citta });
}
