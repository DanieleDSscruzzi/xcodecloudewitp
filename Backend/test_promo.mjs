import worker from "./worker.js";
import { readFileSync } from "fs";

const SECRET = readFileSync("/home/claude/promo_secret.txt", "utf8").trim();
const CODE1 = readFileSync("/home/claude/promo_code1.txt", "utf8").trim();

const kvStore = new Map();
const env = {
  WITP_APP_SECRET: "s3cret",
  ANTHROPIC_API_KEY: "sk-test",
  WITP_PROMO_SECRET: SECRET,
  PROMO_KV: {
    get: async (k, t) => kvStore.has(k) ? (t === "json" ? JSON.parse(kvStore.get(k)) : kvStore.get(k)) : null,
    put: async (k, v) => { kvStore.set(k, v); },
  },
};

globalThis.fetch = async (url, opts) => {
  const body = JSON.parse(opts.body);
  const spotID = "11111111-1111-1111-1111-111111111111";
  return new Response(JSON.stringify({
    content: [{ type: "text", text: JSON.stringify({
      summary: "ok:" + body.model, best_id: spotID,
      spots: [{ id: spotID, probability: 0.9, reason: "t" }]
    })}]
  }), { status: 200, headers: { "content-type": "application/json" } });
};

async function redeem(code, device, secret = "s3cret") {
  const req = new Request("https://api.x/v1/redeem", { method: "POST",
    headers: { "x-witp-app": secret, "x-witp-device": device },
    body: JSON.stringify({ code }) });
  const res = await worker.fetch(req, env);
  return { status: res.status, body: await res.json() };
}
async function reason(promoToken, device) {
  const req = new Request("https://api.x/v1/reason", { method: "POST",
    headers: { "x-witp-app": "s3cret", "x-witp-device": device },
    body: JSON.stringify({ promo: promoToken, context: "t",
      spots: [{ id: "11111111-1111-1111-1111-111111111111", nome: "Via T", tipo: "blu",
                stalli: 5, distanza_m: 50, probabilita_locale: 0.5, motivi_locali: [] }] }) });
  const res = await worker.fetch(req, env);
  return { status: res.status, body: await res.json() };
}

let pass = 0, fail = 0;
const check = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "✓" : "✗"} ${n}${x ? " → " + x : ""}`); };

let r = await redeem("WITP-DEV-AAAAA-BBBBB-CCCCC-DDDDD", "devA");
check("codice falso → 400", r.status === 400);

r = await redeem(CODE1, "devA");
check("riscatto codice #1 (devA) → 200 + token ultraplus",
      r.status === 200 && r.body.tier === "ultraplus" && r.body.token?.includes("."));
const token = r.body.token, exp1 = r.body.expiresAt;
const days = (exp1 - Date.now()) / 86400e3;
check("durata ≈ 60 giorni", days > 59 && days < 61, days.toFixed(1) + "g");

r = await redeem(CODE1, "devA");
check("stesso device ri-riscatta (reinstall) → idempotente", r.status === 200 && r.body.expiresAt === exp1);

r = await redeem(CODE1, "devB");
check("altro device → 409 codice_gia_usato", r.status === 409);

r = await reason(token, "devA");
check("reason SENZA jws ma con promo → 200 Ultra+ (Fable)",
      r.status === 200 && r.body.tier === "ultraplus" && r.body.model === "Claude Fable", r.body.model);

r = await reason(token, "devB");
check("token rubato su altro device → 402", r.status === 402);

r = await reason(token.slice(0, -3) + "AAA", "devA");
check("token manomesso → 402", r.status === 402);

console.log(`\n═══ ${pass} passati · ${fail} falliti ═══`);
process.exit(fail ? 1 : 0);
