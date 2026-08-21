# ZTL — come funzionano

**Automatiche ovunque.** Non devi caricare niente: quando fai uno scan a
Torino, Parigi, Verbania o in qualsiasi altro posto, il backend interroga
OpenStreetMap per quella zona e ti restituisce le ZTL attive.

## Come funziona

1. L'app chiama `/v1/ztl?lat=..&lon=..&r=1500`
2. Il backend cerca prima nel **dato curato** (se qualcuno ha importato
   quella città da fonte ufficiale)
3. Altrimenti interroga **OpenStreetMap** in diretta, con i filtri di
   qualità qui sotto
4. Calcola lo stato ADESSO e restituisce solo le zone **attive** o che si
   attivano **entro 30 minuti**

La risposta è in cache per riquadro geografico (~1 km) per 12 ore: chi
cerca nella stessa zona non fa ripartire la query. Lo **stato** invece è
ricalcolato ogni volta sull'ora italiana reale — un "fino alle 19:30"
deve essere esatto al minuto.

## I filtri di qualità (lato server, correggibili senza aggiornare l'app)

| Filtro | Perché |
|---|---|
| Solo `boundary=limited_traffic_zone` | Le `low_emission_zone` coprono interi comuni: erano loro a far sembrare "tutta la città è ZTL" |
| Niente `admin_level` | Un confine amministrativo taggato per errore non è una ZTL |
| Serve nome **o** orario | Le geometrie anonime e senza regole sono abbozzi incompleti |
| Diagonale tra 100 m e 6 km | Sotto è un errore di digitazione, sopra è una città intera (l'"Area B" di Milano non è una ZTL da centro storico) |

Verificato sul campo: Torino (2,5 km), Firenze (2,7 km), Milano Area C
(5,0 km) e Parigi (2,8 km) passano; Area B di Milano (25 km) e il caso
Genova vengono scartati.

## Se una città manca

Vuol dire che su OpenStreetMap quella ZTL non è mappata. Due strade:

**A — La mappi su OSM** (gratis, aiuta tutti): openstreetmap.org, disegni
il perimetro con `boundary=limited_traffic_zone`, `name` e
`opening_hours`. WITP la vede al prossimo ciclo di cache.

**B — La carichi come dato curato** dal portale open data del Comune, che
ha il perimetro ufficiale e ha la precedenza su OSM:

```bash
curl -X POST https://api.whereistheparking.com/v1/ztl/import \
  -H "x-witp-admin: JPMt84qS3s90BZNMN576LvaDkbbg7iyBAikFR7dmVVTq44O2" \
  -H "content-type: application/json" \
  -d "{
    \"citta\": \"Firenze\",
    \"fonte\": \"Comune di Firenze — open data\",
    \"orariDefault\": \"Mo-Fr 07:30-20:00; Sa 07:30-16:00\",
    \"geojson\": $(cat ztl_firenze.geojson)
  }"
```

Portali utili: aperto.comune.torino.it, opendata.comune.fi.it,
data-rsm.opendata.arcgis.com (Roma), dati.comune.milano.it. Se trovi solo
Shapefile o KML, converti in GeoJSON su mapshaper.org.

## Sintassi degli orari

| Orario reale | Come si scrive |
|---|---|
| Lun-ven 7:30-20:00 | `Mo-Fr 07:30-20:00` |
| Con il sabato diverso | `Mo-Fr 07:30-20:00; Sa 07:30-16:00` |
| Con pausa pranzo | `Mo-Sa 08:00-12:00,14:00-18:00` |
| Sempre attiva | `24/7` |

Nessun orario noto → la zona è considerata **sempre attiva**, per
prudenza: meglio un avviso in più che una multa.

## Cosa vedi sulla mappa

- **gialla** — attiva ora, con "fino alle 19:30"
- **ambra** — si attiva a breve, con "tra 12 min"

Le zone spente non vengono nemmeno inviate all'app.

## Controllo

```bash
curl -H "x-witp-admin: JPMt84qS3s90BZNMN576LvaDkbbg7iyBAikFR7dmVVTq44O2" \
  https://api.whereistheparking.com/v1/ztl/list
```
