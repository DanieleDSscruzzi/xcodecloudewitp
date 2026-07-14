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
  premium:   { chain: ["claude-haiku-4-5"] },
  turbo:     { chain: ["claude-sonnet-4-6"] },
  ultra:     { chain: ["claude-opus-4-8", "claude-sonnet-4-6"] },
  ultraplus: { chain: ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6"] },
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

    // 5) Claude ----------------------------------------------------------------
    try {
      const { verdict, modelUsed } = await askClaude(env.ANTHROPIC_API_KEY, model.chain, body.context, spots);
      return json({ ...verdict, model: MODEL_LABEL[modelUsed] || modelUsed, tier: ent.tier });
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

async function askClaude(apiKey, chain, context, spots) {
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
        max_tokens: 1200,
        system: SYSTEM_PROMPT,
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
