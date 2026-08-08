# WITP — Checklist beta (TestFlight)

## Backend (una volta)
1. `wrangler kv namespace create witp_promo` → copia l'id in `wrangler.toml`
2. `wrangler secret put ANTHROPIC_API_KEY` · `WITP_APP_SECRET` · `WITP_PROMO_SECRET`
   (il promo secret è in witp-dev-codes.txt — NON metterlo mai nell'app)
3. `wrangler deploy` → verifica https://api.whereistheparking.com/v1/health
4. In `ClaudeReasoner.swift` → `BackendConfig.appSecret` = lo stesso WITP_APP_SECRET

## App Store Connect
- Nuova app · bundle `com.danielescruzzi.witp`
- Nome store consigliato: **"WITP — Where Is The Parking"** (senza "Claude" nel
  nome; nella descrizione va benissimo "powered by Claude")
- Abbonamenti, UN gruppo, livelli esatti:
  L1 `cobianchi.WITP.ultraplus.Claude2` €49,99 · L2 `…ultra…` €19,99 ·
  L3 `…turbo…` €12,99 · L4 `…premium…` €6,99
- Accordo Paid Apps attivo · App Privacy: Posizione (funzionale, non tracking),
  Acquisti, Identificatore dispositivo (funzionalità app)

## Build
- ⇧⌘K → Product ▸ Archive → Distribute ▸ TestFlight
- Note per il beta review: nessun account richiesto; serve la posizione;
  per provare Ultra+ usare un codice sviluppatore da Profilo ▸ "Ho un codice"

## PRIMA del lancio pubblico (non serve per la beta)
- `verifyEntitlement` nel worker → App Store Server API (ora decodifica soltanto)
- Codici clienti → Offer Codes ufficiali Apple (i WITP-DEV restano ai dev)
