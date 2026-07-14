# WITP — Where Is The Parking

Una mappa. Un tasto. Una risposta.

Apri l'app, premi **Trova parcheggio**, e WITP ti indica *il* posto dove
andare — con la probabilità reale di trovarlo libero e il motivo. Sotto
il cofano: 3 fonti dati vere, geometria degli stalli 2,5×5 m, un modello
probabilistico deterministico e il ragionamento Claude sui piani a
pagamento. Sopra il cofano: niente di tutto questo. Solo la risposta.

## Architettura

```
iPhone                                 api.whereistheparking.com (Cloudflare Worker)
──────                                 ─────────────────────────────────────────────
Trova parcheggio
  ├─ OSM Overpass  ┐
  ├─ Apple Maps    ├─ geometria reale → modello locale (P = 1−occᴺ)
  └─ parking:lane  ┘                        │
                                            ▼  (solo Premium/Turbo)
                     spots + ricevuta JWS ──►  verifica abbonamento
                                               sceglie Haiku / Sonnet
                     risposta raffinata   ◄──  chiama Claude (chiave SOLO qui)
```

**Nell'app non esiste nessuna chiave API.** Il Worker in `Backend/` verifica
la ricevuta StoreKit 2, decide il modello in base al piano *verificato* e
tiene la chiave Anthropic nei secret di Cloudflare. Se il server non
risponde, l'app usa il modello locale: mai bloccante.

## Build

1. Apri `WITP Definitivo.xcodeproj` (cartella sincronizzata: i file nuovi
   entrano da soli, `Secrets.swift` e `AnalyticsView.swift` non esistono più).
2. **Edit Scheme → Run → Options → StoreKit Configuration → `Products.storekit`**
   (per sviluppo; per TestFlight rimettila su *None*, vedi sotto).
3. In `ClaudeReasoner.swift` incolla in `BackendConfig.appSecret` lo stesso
   valore del secret `WITP_APP_SECRET` del Worker.
4. Run. Senza backend deployato l'app funziona comunque col modello locale.

Test del backend in locale: `cd Backend && wrangler dev`, poi in build DEBUG
`UserDefaults.standard.set("http://localhost:8787", forKey: "witp.backend.url")`.

## Deploy backend (5 minuti)

Vedi `Backend/README.md`. In sintesi:

```bash
cd Backend
wrangler login
wrangler secret put ANTHROPIC_API_KEY   # crediti Claude for Startups
wrangler secret put WITP_APP_SECRET     # stessa stringa di BackendConfig.appSecret
wrangler deploy
curl https://api.whereistheparking.com/v1/health   # {"ok":true}
```

## Abbonamenti in vendita — checklist App Store Connect

I product ID nel codice e in `Products.storekit` sono già quelli definitivi:

- `cobianchi.WITP.premium.Claude2` — €6,99/mese
- `cobianchi.WITP.turbo.Claude2` — €12,99/mese

Su App Store Connect:

1. **Accordi, tasse e dati bancari** → firma il contratto *Paid Apps* e
   completa banca + moduli fiscali. Senza questo i prodotti restano
   "Missing Metadata" e non compaiono mai.
2. **La tua app → Monetizzazione → Abbonamenti** → crea il gruppo
   `WITP` (livello 1 = Turbo, livello 2 = Premium: Turbo è l'upgrade).
3. Crea i due abbonamenti auto-rinnovabili usando **esattamente** gli ID
   qui sopra. Durata: 1 mese. Prezzo: €6,99 e €12,99.
4. Localizzazione IT (e EN) per ciascuno — testi pronti:
   - *Premium*: «Raggio di ricerca 1 km, fino a 15 aree, scelta del
     parcheggio migliore con ragionamento Claude.»
   - *Turbo*: «Raggio 1,5 km, fino a 30 aree, ragionamento Claude di
     livello superiore e priorità massima.»
5. Carica l'**immagine promozionale** dell'abbonamento (1024×1024) e
   compila la *Review Screenshot* per ciascun prodotto.
6. **App Privacy**: Posizione precisa (funzionalità dell'app, non
   collegata all'identità) e ID dispositivo (funzionalità). Il file
   `PrivacyInfo.xcprivacy` nel target dichiara già lo stesso.
7. **TestFlight/Release**: in Xcode, Edit Scheme → StoreKit Configuration
   → **None**. In sandbox e produzione i prodotti arrivano da App Store
   Connect, non dal file locale. Testa l'acquisto con un account Sandbox
   (Impostazioni → App Store → Account sandbox).
8. Note per il revisore: «I piani Premium/Turbo inviano i risultati a un
   nostro server (api.whereistheparking.com) che verifica l'abbonamento e
   interroga l'API Anthropic. Nessuna chiave o dato personale nell'app.»

## Prima del lancio pubblico

- Sostituire `verifyEntitlement()` nel Worker con la verifica completa via
  **App Store Server API** (chiave *In-App Purchase* da ASC). L'interfaccia
  della funzione è già pronta per lo scambio.
- Passare `SessionStore` a CloudKit (già previsto).

## Struttura

```
WITP 4/            app (cartella sincronizzata Xcode)
Backend/           Cloudflare Worker + wrangler.toml + guida deploy
Products.storekit  configurazione StoreKit di sviluppo
```
