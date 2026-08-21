//
//  StreetFinder.swift
//  WITP — WDSL+ (il motore geometrico)
//
//  Disegna parcheggi RISPETTANDO LA GEOMETRIA REALE:
//   1. Poligono vero da OSM (vertici precisi)
//   2. Orientamento dai BORDI del poligono (media circolare pesata per
//      lunghezza): gli stalli seguono i muri del parcheggio, non una
//      diagonale statistica.
//   3. File di stalli 2,5×5 m appaiate schiena-schiena con corsie da 5,5 m,
//      centrate nell'area; lotti stretti → modalità "striscia" parallela.
//   4. Ogni stallo entra SOLO se tutti e 4 gli angoli sono dentro il
//      perimetro: niente rettangoli che sporgono.
//   5. Il numero mostrato = il numero disegnato. Multipiano/interrati:
//      nessuno stallo in superficie, solo il conteggio dichiarato.
//   6. In strada: paralleli LUNGO la via (5,0×2,0), perpendicolari a
//      pettine (2,5×5,0), diagonali a 60°; lato destro/sinistro/entrambi
//      letti dai tag OSM, offset dal centro-strada realistico.
//

import Foundation
import MapKit
import CoreLocation

actor StreetFinder {

    static let shared = StreetFinder()

    // Dimensioni standard italiane (metri)
    private let stallW: Double = 2.5      // larghezza stallo a pettine
    private let stallL: Double = 5.0      // profondità stallo a pettine
    private let parallelL: Double = 5.0   // lunghezza stallo parallelo
    private let parallelW: Double = 2.0   // profondità stallo parallelo
    private let aisle: Double = 5.5       // corsia di manovra
    private let edgeMargin: Double = 0.25 // distanza minima dal perimetro
    private let maxStallsPerSpot = 350    // tetto per performance

    func findParkingSpots(
        near center: CLLocationCoordinate2D,
        radius: Double,
        tier: SubscriptionTier
    ) async -> [ParkingSpot] {

        async let osmGeom = osmParkingWithRealGeometry(near: center, radius: radius)
        async let appleResult = appleParkingPOIs(near: center, radius: radius)
        async let onStreet = onStreetParking(near: center, radius: radius)

        let all = await osmGeom + (await appleResult) + (await onStreet)
        let unique = deduplicate(spots: all)

        // Come in merge(): la mappa mostra tutto, nessun taglio per piano.
        return Array(
            unique.sorted { $0.distanceFromUser < $1.distanceFromUser }
                .prefix(300)
        )
    }

    /// Dedup + ordina; nessun taglio per piano (usato dall'engine).
    func merge(_ spots: [ParkingSpot], tier: SubscriptionTier) -> [ParkingSpot] {
        let unique = deduplicate(spots: spots)
        // La mappa mostra TUTTO quello che il WDSL+ trova. I piani si
        // differenziano su raggio, velocità e modello AI — e su quante aree
        // Claude ragiona (cap lato backend) — MAI nascondendo parcheggi già
        // trovati: prima il Free tagliava a 6 e sembrava tutto sparito.
        // Tetto alto solo di sicurezza per il rendering.
        return Array(
            unique.sorted { $0.distanceFromUser < $1.distanceFromUser }
                .prefix(300)
        )
    }

    // MARK: - Cache + collect (la velocità vera dei piani Ultra)

    private struct CacheEntry {
        let date: Date
        let center: CLLocationCoordinate2D
        let radius: Double
        let spots: [ParkingSpot]
    }
    private var cache: [CacheEntry] = []
    private let cacheTTL: TimeInterval = 15 * 60

    /// Le 3 fonti in parallelo, con cache davanti: la geometria delle strade
    /// non cambia in 15 minuti, quindi la seconda risposta è istantanea —
    /// e col prefetch anche la prima.
    /// Le 3 fonti in parallelo, IN FLUSSO: ogni volta che una fonte
    /// atterra, i risultati parziali escono subito. Apple risponde in
    /// mezzo secondo (il verdetto a 1 s ha già qualcosa), OSM arriva
    /// dopo qualche secondo e completa la mappa con le strisce.
    func collectStream(near center: CLLocationCoordinate2D,
                       radius: Double,
                       window: TimeInterval) -> AsyncStream<[ParkingSpot]> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                if let hit = await self.cachedSpots(center: center, radius: radius) {
                    continuation.yield(hit)
                    continuation.finish()
                    return
                }
                // Memoria CloudKit condivisa: se QUALCUNO ha già scansionato
                // questa zona negli ultimi 30 giorni, la geometria arriva da
                // lì — istantanea, zero Overpass. La stima la rifà comunque
                // il predittore a valle. Timeout stretto: mai bloccante.
                if let cloud = await withTimeout(3.0, {
                    await CloudParkingCache.shared.load(center: center, radius: radius)
                }) ?? nil, !cloud.isEmpty {
                    await self.storeIfRich(center: center, radius: radius, spots: cloud)
                    continuation.yield(cloud)
                    continuation.finish()
                    return
                }
                var collected: [ParkingSpot] = []
                await withTaskGroup(of: [ParkingSpot].self) { group in
                    group.addTask {
                        await self.osmParkingWithRealGeometry(near: center, radius: radius, budget: window)
                    }
                    group.addTask {
                        await withTimeout(window) {
                            await self.appleParkingPOIs(near: center, radius: radius, budget: window)
                        } ?? []
                    }
                    group.addTask {
                        await self.onStreetParking(near: center, radius: radius, budget: window)
                    }
                    for await batch in group {
                        if Task.isCancelled { break }
                        collected += batch
                        continuation.yield(collected)   // parziali SUBITO
                    }
                }
                await self.storeIfRich(center: center, radius: radius, spots: collected)
                // Condividi la scansione: il prossimo che cerca qui la
                // riceve all'istante. Fire-and-forget, mai bloccante.
                let toShare = collected
                Task.detached(priority: .utility) {
                    await CloudParkingCache.shared.save(center: center, radius: radius, spots: toShare)
                }
                continuation.finish()
            }
        }
    }

    func collect(near center: CLLocationCoordinate2D,
                 radius: Double,
                 window: TimeInterval) async -> [ParkingSpot] {
        var last: [ParkingSpot] = []
        for await batch in collectStream(near: center, radius: radius, window: window) {
            last = batch
        }
        return last
    }

    private func cachedSpots(center: CLLocationCoordinate2D, radius: Double) -> [ParkingSpot]? {
        cacheLookup(center: center, radius: radius)
    }

    /// In cache SOLO un risultato ricco (con geometria disegnata): un
    /// risultato di soli POI avvelenerebbe la zona per 15 minuti.
    private func storeIfRich(center: CLLocationCoordinate2D, radius: Double, spots: [ParkingSpot]) {
        guard spots.contains(where: { !$0.stripes.isEmpty }) else { return }
        cache.append(CacheEntry(date: Date(), center: center, radius: radius, spots: spots))
        if cache.count > 24 { cache.removeFirst(cache.count - 24) }
    }

    /// Riscalda la cache intorno a una posizione (piani Ultra/Ultra+):
    /// quando l'utente preme il tasto, la risposta è già qui.
    func prefetch(near center: CLLocationCoordinate2D, radius: Double) async {
        if cacheLookup(center: center, radius: radius) != nil { return }
        _ = await collect(near: center, radius: radius, window: 12)
    }

    private func cacheLookup(center: CLLocationCoordinate2D, radius: Double) -> [ParkingSpot]? {
        let now = Date()
        cache.removeAll { now.timeIntervalSince($0.date) > cacheTTL }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        for entry in cache.reversed() {
            let d = here.distance(from: CLLocation(latitude: entry.center.latitude,
                                                   longitude: entry.center.longitude))
            guard d + radius <= entry.radius + 80 else { continue }
            // Copertura ok: ricalcola le distanze dal NUOVO centro e filtra.
            return entry.spots.compactMap { spot in
                var s = spot
                s.distanceFromUser = here.distance(from: CLLocation(latitude: spot.coordinate.latitude,
                                                                    longitude: spot.coordinate.longitude))
                return s.distanceFromUser <= radius ? s : nil
            }
        }
        return nil
    }

    // MARK: - Garanzia: sosta stimata a bordo strada

    /// Quando NULLA è mappato: le vie residenziali italiane hanno quasi
    /// sempre sosta a bordo strada. La stimiamo, dichiarandola come stima.
    func estimatedKerbside(near center: CLLocationCoordinate2D,
                           radius: Double,
                           budget: TimeInterval) async -> [ParkingSpot] {
        let capped = min(radius, 1200)   // il salvataggio non deve affogare nelle metropoli
        let query = """
        [out:json][timeout:8];
        (
          way["highway"~"^(residential|living_street|unclassified)$"]["name"](around:\(Int(capped)),\(center.latitude),\(center.longitude));
        );
        out geom qt 50;
        """
        guard let elements = await overpass(query, timeout: min(8, max(2, budget))) else { return [] }
        let userLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)

        var candidates: [(dist: Double, spot: ParkingSpot)] = []
        for el in elements {
            guard let geometry = el["geometry"] as? [[String: Any]], geometry.count >= 2 else { continue }
            let tags = el["tags"] as? [String: String] ?? [:]
            var pts: [CLLocationCoordinate2D] = []
            for g in geometry {
                if let lat = g["lat"] as? Double, let lon = g["lon"] as? Double {
                    pts.append(.init(latitude: lat, longitude: lon))
                }
            }
            guard pts.count >= 2 else { continue }
            let mid = pts[pts.count / 2]
            // Distanza dal punto PIÙ VICINO della via, non dal centro: una
            // via lunga ti passa accanto anche se il suo punto medio è
            // lontano — prima l'intera via veniva scartata.
            let dist = nearestDistance(from: userLoc, along: pts)
            guard dist <= radius else { continue }

            let stripes = onStreetStalls(along: pts, type: "parallel", sideSign: +1, zoneType: .free)
            guard !stripes.isEmpty else { continue }
            let name = (tags["name"] ?? "Strada") + " — sosta stimata"
            candidates.append((dist, ParkingSpot(
                coordinate: mid,
                streetName: name,
                zoneType: .free,
                stripes: Array(stripes.prefix(80)),
                confidence: 0.5,
                distanceFromUser: dist,
                stallCountOverride: nil
            )))
        }
        return candidates.sorted { $0.dist < $1.dist }.prefix(4).map(\.spot)
    }

    // MARK: - 1. OSM: poligoni reali

    func osmParkingWithRealGeometry(
        near center: CLLocationCoordinate2D,
        radius: Double,
        budget: TimeInterval = 18
    ) async -> [ParkingSpot] {

        // Grandi città: il tetto `qt N` ordina per QUADRANTE, non per
        // distanza — con un solo anello, a Tokyo, il lotto sotto casa può
        // restare fuori. Due anelli in parallelo: quello vicino è completo
        // (garantisce i più prossimi), quello largo dà l'ampiezza.
        let t = Int(min(18, max(3, budget)))
        func areaQuery(_ r: Double, cap: Int) -> String {
            """
            [out:json][timeout:\(t)];
            (
              way["amenity"="parking"](around:\(Int(r)),\(center.latitude),\(center.longitude));
              relation["amenity"="parking"](around:\(Int(r)),\(center.latitude),\(center.longitude));
              node["amenity"="parking"](around:\(Int(r)),\(center.latitude),\(center.longitude));
            );
            out geom qt \(cap);
            """
        }
        // SCALA ADATTIVA: un anello che torna SATURO (count == cap) non
        // garantisce i più vicini (il quadrante taglia dove vuole) → si
        // scende a un anello più stretto finché uno torna completo.
        // L'anello più interno è piccolo: può permettersi un tetto alto.
        // La scala si AUTO-limita: deadline interna, timeout per anello
        // calato sul tempo residuo, e i parziali si CONSERVANO — così
        // nelle metropoli (3-4 anelli) la vernice arriva comunque, anche
        // se non c'è tempo per l'ultimo anello.
        let deadline = Date().addingTimeInterval(max(1.5, budget - 0.3))
        var elements: [[String: Any]] = []
        var ringR = radius
        for _ in 0..<5 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1.0 else { break }
            let cap = ringR <= 320 ? 400 : 200
            let ring = await overpass(areaQuery(ringR, cap: cap),
                                      timeout: min(18, remaining)) ?? []
            elements += ring
            if ring.count < cap || ringR <= 320 { break }
            ringR *= 0.45
        }
        guard !elements.isEmpty else { return [] }
        let userLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var spots: [ParkingSpot] = []

        for el in elements {
            // Nodo puntuale: piccolo lotto mappato come punto → geometria stimata.
            if (el["type"] as? String) == "node" {
                guard let lat = el["lat"] as? Double, let lon = el["lon"] as? Double else { continue }
                let tags = el["tags"] as? [String: String] ?? [:]
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let dist = userLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
                guard dist <= radius else { continue }
                let zoneType = inferZoneType(tags: tags, distance: dist)
                let declared = Int(tags["capacity"] ?? "")
                // Nodo = punto senza forma: conteggio solo se DICHIARATO in
                // OSM. Niente numeri inventati, niente vernice inventata.
                spots.append(ParkingSpot(
                    coordinate: coord,
                    streetName: tags["name"] ?? tags["operator"] ?? "Parcheggio",
                    zoneType: zoneType,
                    stripes: [],
                    confidence: 0.7,
                    distanceFromUser: dist,
                    stallCountOverride: declared
                ))
                continue
            }

            // Geometria: way normale (chiave "geometry") OPPURE relazione
            // multipoligono — i grandi lotti (supermercati, Esselunga, centri
            // commerciali) sono spesso relation, con la geometria dentro i
            // "members": prima venivano scartati in blocco.
            var vertices: [CLLocationCoordinate2D] = []
            if let geometry = el["geometry"] as? [[String: Any]] {
                for v in geometry {
                    if let lat = v["lat"] as? Double, let lon = v["lon"] as? Double {
                        vertices.append(.init(latitude: lat, longitude: lon))
                    }
                }
            } else if let members = el["members"] as? [[String: Any]] {
                var best: [CLLocationCoordinate2D] = []
                for m in members where (m["role"] as? String ?? "outer") == "outer" {
                    guard let g = m["geometry"] as? [[String: Any]] else { continue }
                    var ring: [CLLocationCoordinate2D] = []
                    for v in g {
                        if let lat = v["lat"] as? Double, let lon = v["lon"] as? Double {
                            ring.append(.init(latitude: lat, longitude: lon))
                        }
                    }
                    if ring.count > best.count { best = ring }
                }
                vertices = best
            }
            guard vertices.count >= 3 else { continue }

            let centroid = polygonCentroid(vertices: vertices)
            // Dentro il raggio se il BORDO più vicino lo è: un lotto grande
            // col centro lontano ma il bordo accanto veniva scartato.
            let dist = min(userLoc.distance(from: CLLocation(latitude: centroid.latitude, longitude: centroid.longitude)),
                           nearestDistance(from: userLoc, along: vertices))
            guard dist <= radius else { continue }

            let tags = el["tags"] as? [String: String] ?? [:]
            let name = tags["name"] ?? tags["operator"] ?? "Parcheggio"
            let zoneType = inferZoneType(tags: tags, distance: dist)
            let isCovered = ["multi-storey", "underground", "rooftop"].contains(tags["parking"] ?? "")
            let declaredCapacity = Int(tags["capacity"] ?? "") ?? 0
            let areaM2 = polygonAreaSquareMeters(vertices: vertices)

            var stripes: [ParkingStripe] = []
            var override: Int? = nil

            if isCovered {
                // Dentro un edificio: disegnare stalli in superficie sarebbe falso.
                override = declaredCapacity > 0 ? declaredCapacity : max(30, Int(areaM2 / 28))
            } else {
                stripes = fillPolygonWithStalls(polygon: vertices, zoneType: zoneType)
                if stripes.isEmpty {
                    // Poligono degenere: mostriamo solo il pin col conteggio stimato.
                    override = declaredCapacity > 0 ? declaredCapacity : max(2, Int(areaM2 / 25))
                }
            }

            spots.append(ParkingSpot(
                coordinate: centroid,
                streetName: name,
                zoneType: zoneType,
                stripes: stripes,
                confidence: 0.92,
                distanceFromUser: dist,
                stallCountOverride: override
            ))
        }
        return spots
    }

    // MARK: - 2. Apple Maps POI (geometria stimata, confidence più bassa)

    func appleParkingPOIs(
        near center: CLLocationCoordinate2D,
        radius: Double,
        budget: TimeInterval = 10
    ) async -> [ParkingSpot] {

        let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking])
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }

        let userLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var spots: [ParkingSpot] = []

        for item in response.mapItems {
            let coord = item.placemark.coordinate
            let dist = userLoc.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            guard dist <= radius else { continue }

            let name = item.name ?? "Parcheggio"
            let lower = name.lowercased()

            let zoneType: ParkingZoneType
            if lower.contains("disabili") { zoneType = .disabled }
            else if lower.contains("riservato") { zoneType = .reserved }
            else if lower.contains("gratuito") || lower.contains("libero") { zoneType = .free }
            else { zoneType = .paid }

            // Apple non espone la capienza dei POI: NESSUN numero inventato.
            // Se lo stesso lotto esiste anche in OSM (quasi sempre), la dedup
            // tiene quella versione — con capacity dichiarata o stalli contati.

            // REGOLA: il quadretto o è vero o non si disegna. I POI Apple
            // non hanno geometria → risposta sì (con conteggio ≈), vernice no.
            // Se lo stesso lotto arriva anche da OSM col poligono vero, la
            // dedup tiene quello (confidence più alta).
            spots.append(ParkingSpot(
                coordinate: coord,
                streetName: name,
                zoneType: zoneType,
                stripes: [],
                confidence: 0.78,
                distanceFromUser: dist,
                stallCountOverride: nil
            ))
        }
        return spots
    }

    // MARK: - 3. In strada (parking:lane) — lati e orientamenti corretti

    func onStreetParking(
        near center: CLLocationCoordinate2D,
        radius: Double,
        budget: TimeInterval = 12
    ) async -> [ParkingSpot] {

        // OSM ha DUE schemi per la sosta in strada: il vecchio
        // `parking:lane:*` e il nuovo `parking:left/right/both` (2022+,
        // dominante in Italia e Francia). Li prendiamo entrambi, con
        // QUALSIASI valore: il filtro fine lo facciamo in codice.
        let t = Int(min(12, max(2, budget)))
        func laneQuery(_ r: Double, cap: Int) -> String {
            let hw = "residential|primary|secondary|tertiary|unclassified|living_street|service|tertiary_link|secondary_link"
            let a = "around:\(Int(r)),\(center.latitude),\(center.longitude)"
            // Schema NUOVO (parking:left/right/both) e VECCHIO
            // (parking:lane:*): due gruppi espliciti, regex SOLO sui valori
            // (sintassi solida ovunque). Presenza-chiave via [key]. Il
            // filtro fine (orientamento, blocchi) lo fa il codice dopo.
            return """
            [out:json][timeout:\(t)];
            (
              way["highway"~"^(\(hw))$"]["parking:both"](\(a));
              way["highway"~"^(\(hw))$"]["parking:left"](\(a));
              way["highway"~"^(\(hw))$"]["parking:right"](\(a));
              way["highway"~"^(\(hw))$"]["parking:lane:both"](\(a));
              way["highway"~"^(\(hw))$"]["parking:lane:left"](\(a));
              way["highway"~"^(\(hw))$"]["parking:lane:right"](\(a));
            );
            out geom qt \(cap);
            """
        }
        let deadline = Date().addingTimeInterval(max(1.2, budget - 0.3))
        var elements: [[String: Any]] = []
        var ringR = radius
        for _ in 0..<5 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.9 else { break }
            let cap = ringR <= 320 ? 400 : 200
            let ring = await overpass(laneQuery(ringR, cap: cap),
                                      timeout: min(12, remaining)) ?? []
            elements += ring
            if ring.count < cap || ringR <= 320 { break }
            ringR *= 0.45
        }
        guard !elements.isEmpty else { return [] }
        let userLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var spots: [ParkingSpot] = []

        for el in elements.prefix(300) {
            if spots.count >= 200 { break }
            guard let geometry = el["geometry"] as? [[String: Any]], geometry.count >= 2 else { continue }
            let tags = el["tags"] as? [String: String] ?? [:]
            let streetName = tags["name"] ?? "Strada"

            var pts: [CLLocationCoordinate2D] = []
            for g in geometry {
                if let lat = g["lat"] as? Double, let lon = g["lon"] as? Double {
                    pts.append(.init(latitude: lat, longitude: lon))
                }
            }
            guard pts.count >= 2 else { continue }

            let mid = pts[pts.count / 2]
            // Viali e strade lunghe: conta il punto PIÙ VICINO della via.
            // Col punto medio, un viale di 1 km che ti costeggia veniva
            // scartato perché il suo centro era fuori raggio.
            let dist = nearestDistance(from: userLoc, along: pts)
            guard dist <= radius else { continue }

            // Zona dai tag OSM veri (residenti/gratis/pagamento), non a occhio.
            let zoneType = inferZoneType(tags: tags, distance: dist)

            // Lati: destro = +90° rispetto alla direzione della way, sinistro = −90°.
            // Supporta ENTRAMBI gli schemi OSM:
            //   nuovo:   parking:right=lane (+ parking:right:orientation=…)
            //   vecchio: parking:lane:right=parallel|marked|…
            func sideInfo(_ side: String) -> String? {
                let blocked: Set<String> = ["no", "separate", "no_parking", "no_stopping", "not_allowed", "none"]
                let orientations: Set<String> = ["parallel", "perpendicular", "diagonal"]
                if let pos = tags["parking:\(side)"] {
                    if blocked.contains(pos) { return nil }
                    if ["lane", "street_side", "on_kerb", "half_on_kerb", "shoulder", "yes"].contains(pos) {
                        let o = tags["parking:\(side):orientation"] ?? "parallel"
                        return orientations.contains(o) ? o : "parallel"
                    }
                }
                if let v = tags["parking:lane:\(side)"] {
                    if blocked.contains(v) { return nil }
                    if orientations.contains(v) { return v }
                    if ["marked", "on_street", "half_on_kerb", "on_kerb", "painted_area_only", "yes"].contains(v) {
                        return "parallel"
                    }
                }
                return nil
            }

            var sides: [(type: String, sign: Double)] = []
            if let b = sideInfo("both") {
                sides = [(b, +1), (b, -1)]
            } else {
                if let r = sideInfo("right") { sides.append((r, +1)) }
                if let l = sideInfo("left")  { sides.append((l, -1)) }
            }
            guard !sides.isEmpty else { continue }

            var stripes: [ParkingStripe] = []
            for side in sides {
                stripes += onStreetStalls(along: pts, type: side.type,
                                          sideSign: side.sign, zoneType: zoneType,
                                          laneTags: tags)
                if stripes.count > 160 { break }
            }
            guard !stripes.isEmpty else { continue }

            spots.append(ParkingSpot(
                coordinate: mid,
                streetName: streetName,
                zoneType: zoneType,
                stripes: Array(stripes.prefix(160)),
                confidence: 0.75,
                distanceFromUser: dist,
                stallCountOverride: nil
            ))
        }
        return spots
    }

    /// Stalli lungo una polilinea, segmento per segmento: seguono le curve.
    private func onStreetStalls(
        along pts: [CLLocationCoordinate2D],
        type: String,
        sideSign: Double,
        zoneType: ParkingZoneType,
        laneTags: [String: String] = [:]
    ) -> [ParkingStripe] {

        let lat0 = pts[0].latitude
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(lat0 * .pi / 180)

        // Offset dal centro-strada: mezza carreggiata REALE (dalle corsie
        // OSM quando ci sono) + mezza profondità stallo. Sui viali a 4
        // corsie l'offset fisso metteva gli stalli in mezzo alla strada.
        let lanes = Double(Int(laneTags["lanes"] ?? "") ?? 2)
        let laneHalf: Double = max(3.0, lanes * 1.55)

        var stripes: [ParkingStripe] = []

        for i in 1..<pts.count {
            let a = pts[i-1], b = pts[i]
            let dx = (b.longitude - a.longitude) * mLon
            let dy = (b.latitude - a.latitude) * mLat
            let segLen = sqrt(dx*dx + dy*dy)
            guard segLen > 3 else { continue }

            let ux = dx / segLen, uy = dy / segLen          // direzione strada
            let px = uy * sideSign, py = -ux * sideSign     // perpendicolare (destra = +)

            // Geometria per tipo (dimensioni lungo-strada × verso-marciapiede)
            let alongSize: Double
            let perpSize: Double
            let step: Double
            let tilt: Double            // rotazione extra (diagonale)
            switch type {
            case "perpendicular":
                alongSize = stallW;    perpSize = stallL;    step = stallW + 0.1;  tilt = 0
            case "diagonal":
                alongSize = stallW;    perpSize = stallL;    step = 3.1;           tilt = .pi / 6 * sideSign
            default: // parallel
                alongSize = parallelL; perpSize = parallelW; step = parallelL + 0.6; tilt = 0
            }

            let perpOffset = laneHalf + perpSize / 2
            let count = min(Int(segLen / step), 60)
            guard count > 0 else { continue }
            let startPad = (segLen - Double(count) * step) / 2 + step / 2

            for s in 0..<count {
                let along = startPad + Double(s) * step
                let cx = along * ux + perpOffset * px
                let cy = along * uy + perpOffset * py

                let cLat = a.latitude  + cy / mLat
                let cLon = a.longitude + cx / mLon

                // Assi dello stallo (con eventuale inclinazione diagonale)
                let ct = cos(tilt), st = sin(tilt)
                let axU = (ux * ct - uy * st, uy * ct + ux * st)   // lato "along"
                let axP = (px * ct - py * st, py * ct + px * st)   // lato "perp"

                stripes.append(makeStall(
                    center: .init(latitude: cLat, longitude: cLon),
                    axisA: axU, sizeA: alongSize,
                    axisB: axP, sizeB: perpSize,
                    mLat: mLat, mLon: mLon,
                    zoneType: zoneType
                ))
            }
        }
        return stripes
    }

    // MARK: - RIEMPIMENTO POLIGONO (il cuore del WDSL+)

    private func fillPolygonWithStalls(
        polygon: [CLLocationCoordinate2D],
        zoneType: ParkingZoneType
    ) -> [ParkingStripe] {

        guard polygon.count >= 3 else { return [] }

        let centroid = polygonCentroid(vertices: polygon)
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(centroid.latitude * .pi / 180)

        // Vertici in metri locali
        let raw: [(Double, Double)] = polygon.map {
            (($0.longitude - centroid.longitude) * mLon,
             ($0.latitude  - centroid.latitude)  * mLat)
        }

        // ORIENTAMENTO: media circolare dei BORDI pesata per lunghezza
        // (angoli mod 180° con il trucco dell'angolo doppio).
        var sumC = 0.0, sumS = 0.0
        for i in 0..<raw.count {
            let (x1, y1) = raw[i]
            let (x2, y2) = raw[(i + 1) % raw.count]
            let ex = x2 - x1, ey = y2 - y1
            let len = sqrt(ex*ex + ey*ey)
            guard len > 0.5 else { continue }
            let theta = atan2(ey, ex)
            sumC += len * cos(2 * theta)
            sumS += len * sin(2 * theta)
        }
        let axis = 0.5 * atan2(sumS, sumC)   // direzione dominante dei muri
        let cosA = cos(axis), sinA = sin(axis)

        // Ruota nel frame locale (u = lungo i muri, v = perpendicolare)
        let local: [(Double, Double)] = raw.map { (x, y) in
            (x * cosA + y * sinA, -x * sinA + y * cosA)
        }

        let uMin = local.map(\.0).min()!, uMax = local.map(\.0).max()!
        let vMin = local.map(\.1).min()!, vMax = local.map(\.1).max()!
        let depth = vMax - vMin

        var stripes: [ParkingStripe] = []

        func emit(u: Double, v: Double, alongLen: Double, perpLen: Double) {
            guard stripes.count < maxStallsPerSpot else { return }
            // Tutti e 4 gli angoli (+ centro) devono stare nel poligono.
            let hu = alongLen / 2 - 0.05, hv = perpLen / 2 - 0.05
            let corners = [(u-hu, v-hv), (u+hu, v-hv), (u+hu, v+hv), (u-hu, v+hv), (u, v)]
            for (cu, cv) in corners where !pointInPolygon(u: cu, v: cv, polygon: local) { return }

            let ax = (cosA, sinA)                 // asse u riportato al mondo
            let bx = (-sinA, cosA)                // asse v
            let wx = u * ax.0 + v * bx.0
            let wy = u * ax.1 + v * bx.1
            let c = CLLocationCoordinate2D(latitude: centroid.latitude + wy / mLat,
                                           longitude: centroid.longitude + wx / mLon)
            stripes.append(makeStall(center: c,
                                     axisA: ax, sizeA: alongLen,
                                     axisB: bx, sizeB: perpLen,
                                     mLat: mLat, mLon: mLon,
                                     zoneType: zoneType))
        }

        if depth < stallL + 2 * edgeMargin {
            // ── Lotto stretto: striscia di stalli PARALLELI all'asse
            let rows = max(1, Int((depth - 2 * edgeMargin) / (parallelW + 0.3)))
            let rowSpan = Double(rows) * (parallelW + 0.3)
            let v0 = vMin + (depth - rowSpan) / 2 + (parallelW + 0.3) / 2
            for r in 0..<rows {
                let v = v0 + Double(r) * (parallelW + 0.3)
                var u = uMin + edgeMargin + parallelL / 2
                while u <= uMax - edgeMargin - parallelL / 2 {
                    emit(u: u, v: v, alongLen: parallelL, perpLen: parallelW)
                    u += parallelL + 0.4
                }
            }
        } else {
            // ── Lotto normale: coppie di file schiena-schiena + corsie,
            //    il tutto CENTRATO in profondità.
            var rowVs: [Double] = []
            var cursor = 0.0
            var placePair = true
            while true {
                let need = placePair ? 2 * stallL : stallL
                if cursor + need > depth - 2 * edgeMargin { 
                    if placePair { placePair = false; continue } else { break }
                }
                if placePair {
                    rowVs.append(cursor + stallL / 2)
                    rowVs.append(cursor + stallL * 1.5)
                    cursor += 2 * stallL + aisle
                } else {
                    rowVs.append(cursor + stallL / 2)
                    cursor += stallL + aisle
                }
            }
            let used = (rowVs.map { $0 + stallL / 2 }.max() ?? 0)
            let shift = vMin + edgeMargin + (depth - 2 * edgeMargin - used) / 2
            for rv in rowVs {
                let v = shift + rv
                var u = uMin + edgeMargin + stallW / 2
                while u <= uMax - edgeMargin - stallW / 2 {
                    emit(u: u, v: v, alongLen: stallW, perpLen: stallL)
                    u += stallW + 0.05
                }
            }
        }

        return stripes
    }

    /// Crea uno stallo dati centro, due assi unitari (mondo) e dimensioni.
    private func makeStall(
        center: CLLocationCoordinate2D,
        axisA: (Double, Double), sizeA: Double,
        axisB: (Double, Double), sizeB: Double,
        mLat: Double, mLon: Double,
        zoneType: ParkingZoneType
    ) -> ParkingStripe {
        let inset = 0.15
        let ha = (sizeA - inset * 2) / 2
        let hb = (sizeB - inset * 2) / 2

        func pt(_ sa: Double, _ sb: Double) -> CLLocationCoordinate2D {
            let x = sa * ha * axisA.0 + sb * hb * axisB.0
            let y = sa * ha * axisA.1 + sb * hb * axisB.1
            return .init(latitude: center.latitude + y / mLat,
                         longitude: center.longitude + x / mLon)
        }
        return ParkingStripe(
            polygon: [pt(-1, -1), pt(1, -1), pt(1, 1), pt(-1, 1)],
            center: center,
            zoneType: zoneType
        )
    }

    // MARK: - Geometria di base

    private func polygonCentroid(vertices: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        var sLat = 0.0, sLon = 0.0
        for v in vertices { sLat += v.latitude; sLon += v.longitude }
        return .init(latitude: sLat / Double(vertices.count),
                     longitude: sLon / Double(vertices.count))
    }

    private func polygonAreaSquareMeters(vertices: [CLLocationCoordinate2D]) -> Double {
        guard vertices.count >= 3 else { return 0 }
        let c = polygonCentroid(vertices: vertices)
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(c.latitude * .pi / 180)
        let pts = vertices.map { (($0.longitude - c.longitude) * mLon, ($0.latitude - c.latitude) * mLat) }
        var area = 0.0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            area += pts[i].0 * pts[j].1 - pts[j].0 * pts[i].1
        }
        return abs(area) / 2
    }

    private func pointInPolygon(u: Double, v: Double, polygon: [(Double, Double)]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let (xi, yi) = polygon[i]
            let (xj, yj) = polygon[j]
            if ((yi > v) != (yj > v)) && (u < (xj - xi) * (v - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }



    // MARK: - Rete e classificazione

    private func overpass(_ query: String, timeout: TimeInterval) async -> [[String: Any]]? {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter"),
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "data=\(encoded)".data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else { return nil }
            return elements
        } catch { return nil }
    }

    /// Distanza minima utente→polilinea, campionando al massimo ~24 punti:
    /// costo costante anche su vie lunghissime.
    private func nearestDistance(from user: CLLocation, along pts: [CLLocationCoordinate2D]) -> Double {
        guard !pts.isEmpty else { return .greatestFiniteMagnitude }
        let step = max(1, pts.count / 24)
        var best = Double.greatestFiniteMagnitude
        var i = 0
        while i < pts.count {
            let d = user.distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
            if d < best { best = d }
            i += step
        }
        if let last = pts.last {
            best = min(best, user.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)))
        }
        return best
    }

    private func inferZoneType(tags: [String: String], distance: Double) -> ParkingZoneType {
        let fee = tags["fee"]?.lowercased()
        let access = tags["access"]?.lowercased()

        if tags["disabled"] == "yes" || tags["wheelchair"] == "designated" ||
           tags["parking:disabled"] == "yes" { return .disabled }

        // Residenti / permesso → riservato (in UI: "Residenti")
        let permitTags = [tags["parking:condition:both"], tags["parking:condition:right"],
                          tags["parking:condition:left"], tags["access"], tags["parking"]]
            .compactMap { $0?.lowercased() }
        if access == "private" || access == "permit" ||
           permitTags.contains(where: { $0.contains("residents") || $0.contains("permit") || $0.contains("customers") }) {
            return .reserved
        }

        // A PAGAMENTO solo se i tag lo dicono (strisce blu)
        let paidSignals = fee == "yes"
            || tags["parking:fee"] == "yes"
            || tags["parking:both:fee"] == "yes"
            || tags["parking:right:fee"] == "yes"
            || tags["parking:left:fee"] == "yes"
            || (tags["parking:condition:both"]?.contains("ticket") ?? false)
            || (tags["parking:condition:both"]?.contains("disc") ?? false)
        if paidSignals { return .paid }

        // GRATIS: esplicito, o in mancanza di segnali di pagamento
        if fee == "no" { return .free }
        return .free
    }

    private func deduplicate(spots: [ParkingSpot]) -> [ParkingSpot] {
        // Prima gli spot CON geometria: un poligono OSM assorbe il pallino Apple.
        let ordered = spots.sorted { a, b in
            let ga = !a.stripes.isEmpty, gb = !b.stripes.isEmpty
            if ga != gb { return ga }
            return a.confidence > b.confidence
        }
        var unique: [ParkingSpot] = []
        for spot in ordered {
            let dup = unique.firstIndex { existing in
                let d = CLLocation(latitude: existing.coordinate.latitude, longitude: existing.coordinate.longitude)
                    .distance(from: CLLocation(latitude: spot.coordinate.latitude, longitude: spot.coordinate.longitude))
                // 60 m SOLO per assorbire un pin senza geometria (Apple) nel
                // parcheggio disegnato vicino. Tra due spot ENTRAMBI disegnati
                // (es. segmenti adiacenti della stessa via) si fonde solo se
                // praticamente sovrapposti: sono posti veri, non doppioni.
                let bothDrawn = !existing.stripes.isEmpty && !spot.stripes.isEmpty
                return d < (bothDrawn ? 20 : 60)
            }
            if let idx = dup {
                if unique[idx].stripes.isEmpty && !spot.stripes.isEmpty {
                    unique[idx] = spot
                } else if unique[idx].confidence < spot.confidence && unique[idx].stripes.isEmpty {
                    unique[idx] = spot
                }
            } else {
                unique.append(spot)
            }
        }
        return unique
    }
}


