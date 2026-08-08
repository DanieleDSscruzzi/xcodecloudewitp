# WITP API — deploy in 5 minuti

Il Worker è l'unico posto dove vive la chiave Anthropic. Da qui in poi
l'app non chiede mai una chiave all'utente: compri l'abbonamento, funziona.

## Deploy

```bash
npm install -g wrangler
cd Backend
wrangler login                          # apre il browser sul tuo account Cloudflare

wrangler secret put ANTHROPIC_API_KEY   # incolla la sk-ant-… (crediti Claude for Startups)
wrangler secret put WITP_APP_SECRET     # inventa una stringa lunga (es. `openssl rand -hex 24`)

wrangler deploy
```

La route `api.whereistheparking.com/*` viene creata automaticamente perché
il dominio è già sulla tua zona Cloudflare. Verifica con:

```bash
curl https://api.whereistheparking.com/v1/health   # → {"ok":true}
```

## Collega l'app

In `WITP 4/ClaudeReasoner.swift` c'è `BackendConfig.appSecret`:
incolla **la stessa stringa** usata in `WITP_APP_SECRET`. Fine.

Per testare in locale prima del deploy: `wrangler dev` e, in build DEBUG,
imposta l'URL locale con:
`UserDefaults.standard.set("http://localhost:8787", forKey: "witp.backend.url")`

## Sicurezza — cosa fa e cosa non fa (onestamente)

- ✅ La chiave Anthropic non è mai nell'app né nel traffico dell'app.
- ✅ Il modello (Haiku/Sonnet) lo decide il server in base al prodotto
  nella ricevuta: un client Premium non può chiedere Sonnet.
- ✅ Ricevute scadute, bundle sbagliati o prodotti sconosciuti → 402.
- ✅ Rate limit per dispositivo (60/giorno, best-effort).
- ⚠️ v1 decodifica la ricevuta firmata ma non ne verifica la firma lato
  server (la verifica crittografica avviene già su iPhone via StoreKit 2).
  Prima del lancio pubblico: sostituire SOLO `verifyEntitlement()` con la
  verifica via App Store Server API (chiave "In-App Purchase" da App Store
  Connect). L'interfaccia della funzione è già pronta per lo scambio.
