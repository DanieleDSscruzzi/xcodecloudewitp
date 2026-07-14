import worker from "./worker.js";

const env = { WITP_APP_SECRET: "s3cret", ANTHROPIC_API_KEY: "sk-test" };
let fableAvailable = false;
const modelCalls = [];

globalThis.fetch = async (url, opts) => {
  const body = JSON.parse(opts.body);
  modelCalls.push(body.model);
  if (body.model === "claude-fable-5" && !fableAvailable)
    return new Response("model not found", { status: 404 });
  const spotID = "11111111-1111-1111-1111-111111111111";
  return new Response(JSON.stringify({
    content: [{ type: "text", text: JSON.stringify({
      summary: "ok", best_id: spotID,
      spots: [{ id: spotID, probability: 0.8, reason: "test" }]
    })}]
  }), { status: 200, headers: { "content-type": "application/json" } });
};

const b64 = o => Buffer.from(JSON.stringify(o)).toString("base64url");
const jws = (productId, exp = Date.now() + 3600e3) =>
  `${b64({alg:"ES256"})}.${b64({bundleId:"com.danielescruzzi.witp", productId, expiresDate: exp, environment:"Xcode"})}.sig`;

async function call({ product, secret = "s3cret", device = "dev-" + Math.random(), exp, path = "/v1/reason", spots }) {
  const body = { jws: product ? jws(product, exp) : undefined, context: "test",
    spots: spots ?? [{ id: "11111111-1111-1111-1111-111111111111", nome: "Via Test", tipo: "blu",
                       stalli: 10, distanza_m: 100, probabilita_locale: 0.5, motivi_locali: [] }] };
  const req = new Request("https://api.x" + path, { method: path === "/v1/health" ? "GET" : "POST",
    headers: { "x-witp-app": secret, "x-witp-device": device }, body: path === "/v1/health" ? undefined : JSON.stringify(body) });
  const res = await worker.fetch(req, env);
  let j = null; try { j = await res.json(); } catch {}
  return { status: res.status, body: j };
}

let pass = 0, fail = 0;
const check = (name, cond, extra = "") => { cond ? pass++ : fail++; console.log(`${cond ? "✓" : "✗"} ${name}${extra ? "  → " + extra : ""}`); };

// 1) health
let r = await call({ path: "/v1/health" });
check("health 200", r.status === 200 && r.body.ok === true);

// 2) segreto sbagliato
r = await call({ product: "cobianchi.WITP.premium.Claude2", secret: "wrong" });
check("segreto sbagliato → 401", r.status === 401);

// 3) senza abbonamento / scaduto
r = await call({ product: null });
check("senza JWS → 402", r.status === 402);
r = await call({ product: "cobianchi.WITP.turbo.Claude2", exp: Date.now() - 90_000 });
check("abbonamento scaduto → 402", r.status === 402);
r = await call({ product: "prodotto.finto" });
check("prodotto sconosciuto → 402", r.status === 402);

// 4) modello giusto per ogni piano
modelCalls.length = 0;
r = await call({ product: "cobianchi.WITP.premium.Claude2" });
check("Premium → Haiku", r.status === 200 && r.body.model === "Claude Haiku", modelCalls.join(","));
modelCalls.length = 0;
r = await call({ product: "cobianchi.WITP.turbo.Claude2" });
check("Turbo → Sonnet", r.status === 200 && r.body.model === "Claude Sonnet", modelCalls.join(","));
modelCalls.length = 0;
r = await call({ product: "cobianchi.WITP.ultra.Claude2" });
check("Ultra → Opus 4.8", r.status === 200 && r.body.model === "Claude Opus", modelCalls.join(","));

// 5) Ultra+ con Fable NON disponibile → fallback a Opus, dichiarato
modelCalls.length = 0;
r = await call({ product: "cobianchi.WITP.ultraplus.Claude2" });
check("Ultra+ senza Fable → prova fable-5 poi ripiega su Opus",
      r.status === 200 && r.body.model === "Claude Opus" &&
      modelCalls[0] === "claude-fable-5" && modelCalls[1] === "claude-opus-4-8",
      modelCalls.join(" → "));

// 6) Ultra+ con Fable disponibile
fableAvailable = true;
modelCalls.length = 0;
r = await call({ product: "cobianchi.WITP.ultraplus.Claude2" });
check("Ultra+ con Fable → Claude Fable, un solo tentativo",
      r.status === 200 && r.body.model === "Claude Fable" && modelCalls.length === 1,
      modelCalls.join(","));
check("verdetto integro (summary, best_id, spots[0].probability)",
      r.body.summary === "ok" && r.body.best_id && r.body.spots?.[0]?.probability === 0.8);
check("tier dichiarato nella risposta", r.body.tier === "ultraplus");

// 7) rate limit per dispositivo
let last = 0;
for (let i = 0; i < 61; i++) {
  const rr = await call({ product: "cobianchi.WITP.premium.Claude2", device: "same-device" });
  last = rr.status;
}
check("61ª richiesta stesso device → 429", last === 429);

// 8) body malformato
{
  const req = new Request("https://api.x/v1/reason", { method: "POST",
    headers: { "x-witp-app": "s3cret", "x-witp-device": "d" }, body: "{not json" });
  const res = await worker.fetch(req, env);
  check("JSON rotto → 400", res.status === 400);
}

console.log(`\n═══ ${pass} passati · ${fail} falliti ═══`);
process.exit(fail ? 1 : 0);
