//
//  CloudParkingCache.swift
//  WITP — Memoria condivisa dei parcheggi su CloudKit (database PUBBLICO).
//
//  La GEOMETRIA di una zona (stalli disegnati, poligoni, pillole) cambia
//  raramente: la prima scansione — di CHIUNQUE — la salva su CloudKit, e
//  tutte le successive nella stessa zona la ricevono all'istante, senza
//  interrogare OpenStreetMap. La STIMA di disponibilità NON viene mai
//  salvata: la ricalcola il predittore a ogni scansione, fresca.
//
//  ⚠️ REQUISITO XCODE (una volta sola): target WITP → Signing &
//  Capabilities → + Capability → iCloud → spunta CloudKit. Senza questo
//  l'accesso a CloudKit fa crashare l'app al primo scan.
//
//  Tutto best-effort: errori di rete/iCloud → silenzio, si scansiona
//  normalmente come prima. Nessuna dipendenza dalla riuscita.
//

import Foundation
import CloudKit
import CoreLocation

actor CloudParkingCache {
    static let shared = CloudParkingCache()

    private let recordType = "WITPParkingTile"
    private let maxAge: TimeInterval = 60 * 60 * 24 * 30   // 30 giorni
    private var unavailable = false   // errore hard → spenta per la sessione

    /// ANTI-CRASH: senza la capability iCloud→CloudKit (o senza account),
    /// il token è nil e CloudKit NON viene mai toccato — l'app vive e la
    /// memoria condivisa resta semplicemente spenta. Toccare CKContainer
    /// senza entitlement solleva un'eccezione fatale: mai rischiarlo.
    private var entitled: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
    private var warnedOff = false
    private func explainOff() {
        guard !warnedOff else { return }
        warnedOff = true
        print("""
        ☁️ Memoria condivisa SPENTA. Per accenderla servono ENTRAMBE:
           1) Xcode → target WITP → Signing & Capabilities → iCloud →
              spunta CloudKit **e Key-Value storage** (la seconda dà
              l'identità iCloud che uso come interruttore sicuro)
           2) iCloud LOGGATO sul dispositivo/simulatore: nel simulatore
              Impostazioni → Accedi (di default NON è loggato!)
        Senza, l'app funziona normale ma niente memoria condivisa.
        """)
    }

    /// Chiave zona: centro quantizzato (~440 m di griglia) + raggio.
    /// Scansioni vicine cadono nella stessa cella → stessa memoria.
    private func tileKey(center: CLLocationCoordinate2D, radius: Double) -> String {
        let qLat = (center.latitude  * 250).rounded() / 250
        let qLon = (center.longitude * 250).rounded() / 250
        return String(format: "tile_%.4f_%.4f_r%d", qLat, qLon, Int(radius))
    }

    // MARK: - Lettura

    /// Parcheggi già scansionati per questa zona, se presenti e freschi
    /// (max 30 giorni). La distanza viene ricalcolata sul centro ATTUALE;
    /// la disponibilità riparte neutra e la rifà il predittore.
    func load(center: CLLocationCoordinate2D, radius: Double) async -> [ParkingSpot]? {
        guard !unavailable else { return nil }
        guard entitled else { explainOff(); return nil }
        // Prima la cella col MIO raggio; se non c'è, le celle della stessa
        // zona coi raggi MAGGIORI (scansioni fatte da piani più alti): un
        // raggio grande CONTIENE il mio — basta filtrare alla mia distanza.
        // Così l'utente Premium riusa la scansione dell'utente Ultra+.
        let tiers: [Double] = [400, 1000, 1500, 2000, 2500]
        let candidates = [radius] + tiers.filter { $0 > radius }
        for r in candidates {
            if let spots = await fetchTile(center: center, radius: r, clipTo: radius),
               !spots.isEmpty {
                return spots
            }
        }
        return nil
    }

    private func fetchTile(center: CLLocationCoordinate2D,
                           radius: Double,
                           clipTo: Double) async -> [ParkingSpot]? {
        let key = tileKey(center: center, radius: radius)
        do {
            let db = CKContainer.default().publicCloudDatabase
            let record = try await db.record(for: CKRecord.ID(recordName: key))
            guard let stamp = record["stamp"] as? Date,
                  Date().timeIntervalSince(stamp) < maxAge,
                  let asset = record["payload"] as? CKAsset,
                  let url = asset.fileURL,
                  let raw = try? Data(contentsOf: url)
            else { return nil }
            let json = (try? (raw as NSData).decompressed(using: .zlib) as Data) ?? raw
            let dtos = try JSONDecoder().decode([SpotDTO].self, from: json)
            let user = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let spots = dtos.map { $0.toSpot(from: user) }
                .filter { $0.distanceFromUser <= clipTo }   // taglio al MIO piano
            if !spots.isEmpty {
                print("☁️ CloudKit HIT (cella r\(Int(radius))): \(spots.count) parcheggi dalla memoria condivisa — zero Overpass")
            }
            return spots.isEmpty ? nil : spots
        } catch let e as CKError where e.code == .unknownItem {
            return nil        // questa cella non esiste: si prova la prossima
        } catch {
            return nil        // rete/iCloud giù: si va di scansione classica
        }
    }

    // MARK: - Scrittura

    /// Salva la zona su CloudKit (solo risultati RICCHI, con geometria
    /// disegnata — mai i risultati monchi). Fire-and-forget.
    /// Nota: la LETTURA dal database pubblico funziona anche senza account
    /// iCloud; la SCRITTURA richiede un account — se manca, silenzio.
    func save(center: CLLocationCoordinate2D, radius: Double, spots: [ParkingSpot]) async {
        guard !unavailable else { return }
        guard entitled else { explainOff(); return }
        guard spots.contains(where: { !$0.stripes.isEmpty }) else { return }
        let key = tileKey(center: center, radius: radius)
        do {
            let dtos = spots.map(SpotDTO.init)
            let json = try JSONEncoder().encode(dtos)
            let packed = (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(key + ".witp")
            try packed.write(to: tmp, options: .atomic)

            let record = CKRecord(recordType: recordType,
                                  recordID: CKRecord.ID(recordName: key))
            record["stamp"] = Date() as NSDate
            record["payload"] = CKAsset(fileURL: tmp)
            let db = CKContainer.default().publicCloudDatabase
            // .allKeys = upsert: sovrascrive la versione precedente della
            // zona senza conflitti (l'ultima scansione ricca vince).
            _ = try await db.modifyRecords(saving: [record], deleting: [],
                                           savePolicy: .allKeys)
            print("☁️ CloudKit: zona salvata nella memoria condivisa (\(spots.count) parcheggi, \(packed.count / 1024) KB)")
        } catch {
            return   // best-effort: la condivisione fallita non è un errore
        }
    }
}

// MARK: - DTO compatti (SOLO geometria: la stima non si salva mai)

private nonisolated struct CoordDTO: Codable {
    let a: Double, o: Double
    init(_ c: CLLocationCoordinate2D) { a = c.latitude; o = c.longitude }
    var coord: CLLocationCoordinate2D { .init(latitude: a, longitude: o) }
}

private nonisolated struct StripeDTO: Codable {
    let p: [CoordDTO]
    let c: CoordDTO
    let z: String
    init(_ s: ParkingStripe) {
        p = s.polygon.map(CoordDTO.init)
        c = CoordDTO(s.center)
        z = s.zoneType.rawValue
    }
    var stripe: ParkingStripe {
        ParkingStripe(polygon: p.map(\.coord),
                      center: c.coord,
                      zoneType: ParkingZoneType(rawValue: z) ?? .free)
    }
}

private nonisolated struct SpotDTO: Codable {
    let c: CoordDTO
    let n: String
    let z: String
    let s: [StripeDTO]
    let cf: Double
    let so: Int?
    init(_ spot: ParkingSpot) {
        c = CoordDTO(spot.coordinate)
        n = spot.streetName
        z = spot.zoneType.rawValue
        s = spot.stripes.map(StripeDTO.init)
        cf = spot.confidence
        so = spot.stallCountOverride
    }
    /// Ricostruisce lo spot per il centro ATTUALE dell'utente: distanza
    /// ricalcolata, disponibilità neutra (il predittore la rifà subito).
    func toSpot(from user: CLLocation) -> ParkingSpot {
        let coord = c.coord
        let d = user.distance(from: CLLocation(latitude: coord.latitude,
                                               longitude: coord.longitude))
        return ParkingSpot(coordinate: coord,
                           streetName: n,
                           zoneType: ParkingZoneType(rawValue: z) ?? .free,
                           stripes: s.map(\.stripe),
                           confidence: cf,
                           distanceFromUser: d,
                           stallCountOverride: so)
    }
}
