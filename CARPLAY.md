# WITP su CarPlay — come attivarlo

Guida per far funzionare l'interfaccia CarPlay di WITP, dalla richiesta
ad Apple fino al test in auto.

---

## ⚠️ Prima di tutto: serve l'autorizzazione di Apple

CarPlay **non si attiva da solo**. Serve una capability che Apple deve
approvare caso per caso, e senza quella il progetto **non compila
nemmeno** (la firma fallisce).

**Richiedila subito**, perché i tempi non sono brevi:

1. Vai su **developer.apple.com/contact/carplay**
2. Scegli la categoria **Parking**
3. Compila la richiesta descrivendo l'app. Un testo che funziona:

> WITP (Where Is The Parking) is a parking app already published on the
> App Store. It shows real on-street parking stalls and parking areas on
> a map, with an AI that recommends the best spot. The CarPlay interface
> would let drivers see nearby available parking and start navigation to
> the chosen spot, using CPPointOfInterestTemplate. The search runs
> automatically when CarPlay connects, results are limited to five, there
> is no text input, and each result offers a single action ("Navigate"),
> to keep driver interaction to a minimum.

4. Aspetta la risposta via email (giorni o settimane, dipende)

Quando Apple approva, la capability compare nel tuo account developer e
il profilo di provisioning va rigenerato.

---

## Nel frattempo: come compilare senza l'autorizzazione

L'entitlement è già nel file `WITP Claude.entitlements`:

```xml
<key>com.apple.developer.carplay-parking</key>
<true/>
```

Finché Apple non approva, quella riga **fa fallire la firma**. Per
continuare a lavorare sull'app normale, commentala:

```xml
<!-- <key>com.apple.developer.carplay-parking</key>
<true/> -->
```

Il resto del codice CarPlay resta nel progetto senza dare fastidio: la
scena semplicemente non viene mai creata.

---

## Cosa è già pronto nel progetto

| Pezzo | Dove | Stato |
|---|---|---|
| Interfaccia CarPlay | `CarPlaySceneDelegate.swift` | ✅ completa |
| Dichiarazione scena | `Info.plist` → `UIApplicationSceneManifest` | ✅ fatta |
| Entitlement | `WITP Claude.entitlements` | ✅ presente (da attivare dopo l'ok) |
| Registrazione nel target | `project.pbxproj` | ✅ fatta |

Non devi aggiungere niente a mano.

---

## Come è fatta l'interfaccia, e perché

Chi guarda quel display **sta guidando**. Ogni scelta nasce da lì:

**La ricerca parte da sola.** Appena l'auto si collega, WITP cerca
attorno alla posizione. Il guidatore non deve toccare niente per avere
la risposta.

**Niente tastiera.** In CarPlay non si scrive mai. La ricerca per
indirizzo resta sull'iPhone, dove ha senso usarla da fermi.

**Massimo cinque risultati**, anche quando ne trova duecento. Una lista
lunga su un display in movimento è una lista che non si legge.

**Una sola azione per risultato: "Naviga".** Nessun menu, nessun
sottolivello.

**Testi corti.** `180 m · 70% · gratis` si legge in un colpo d'occhio.

**Avviso ZTL in testa alla riga.** Se il parcheggio è dentro una zona a
traffico limitato attiva, il display lo dice **prima** che il guidatore
ci si diriga — è l'informazione che evita la multa, ed è il motivo per
cui vale la pena avere WITP sul cruscotto.

**La mappa non si aggiorna da sola** quando il guidatore la sposta.
Comportamento prevedibile: la ricerca resta legata alla posizione reale
dell'auto.

Apple applica queste stesse regole in revisione ed è severa: le
interfacce CarPlay che distraggono vengono respinte.

---

## Come testarlo senza avere una macchina compatibile

**Simulatore CarPlay (il modo più comodo)**

1. Avvia l'app in un simulatore iPhone da Xcode
2. Nel menu del Simulatore: **I/O → External Displays → CarPlay**
3. Si apre una finestra che simula il display dell'auto
4. Nella schermata CarPlay simulata trovi l'icona di WITP

Nota: nel simulatore la posizione va impostata a mano, altrimenti
compare "Posizione non disponibile" — **Features → Location → Custom
Location** e metti delle coordinate di città.

**Su un'auto vera**

Serve un dispositivo con profilo di provisioning che includa la
capability approvata. Colleghi l'iPhone all'auto e WITP appare tra le
app CarPlay.

---

## Se qualcosa non funziona

**L'icona di WITP non compare in CarPlay**
La capability non è approvata o il profilo di provisioning è vecchio.
In Xcode: Signing & Capabilities → togli e rimetti il team per
rigenerare il profilo.

**Il display resta su "Cerco parcheggio…"**
La posizione non è disponibile. Nel simulatore impostala come sopra;
su iPhone vero controlla che WITP abbia il permesso di posizione.

**"Nessun parcheggio qui"**
Zona non mappata su OpenStreetMap, oppure rete assente. Prova in un
centro cittadino.

**L'app normale non parte più dopo aver aggiunto CarPlay**
Quasi sempre è lo scene manifest scritto male. Quello nel progetto
dichiara **solo** la scena CarPlay: con il ciclo di vita SwiftUI la
scena principale la fornisce il sistema, e non va aggiunta a mano.

---

## Quando pubblichi

Nella descrizione su App Store aggiungi che l'app supporta CarPlay, e
allega uno screenshot dell'interfaccia CarPlay: Apple lo apprezza e gli
utenti lo cercano.

By D.S.
