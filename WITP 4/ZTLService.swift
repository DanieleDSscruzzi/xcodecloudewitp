//
//  ZTLService.swift
//  WITP — zone a traffico limitato da dataset curato.
//
//  PERCHÉ NON OPENSTREETMAP: le ZTL italiane su OSM sono mappate in modo
//  incompleto (poche decine di città su circa 350 che ne hanno una) e a
//  volte con poligoni che coprono un intero comune — da cui i falsi
//  allarmi tipo "tutta la città è ZTL". I Comuni invece pubblicano il
//  dato ufficiale (perimetro, orari, varchi) sui propri portali open data.
//
//  Il backend WITP tiene quel dato, importato città per città da fonti
//  ufficiali, e restituisce SOLO le zone attive adesso o che si attivano
//  entro 30 minuti — con l'orario esatto in cui cambiano stato.
//

import Foundation
import CoreLocation

/// Una ZTL rilevante adesso: o attiva, o in procinto di attivarsi.
struct ZTLZone: Identifiable {
    enum State {
        case active(until: Int?)     // minuti da mezzanotte; nil = sempre attiva
        case upcoming(at: Int)       // minuti da mezzanotte in cui si attiva

        var isActive: Bool { if case .active = self { return true }; return false }

        /// Etichetta per la mappa: "fino alle 19:30" oppure "tra 12 min".
        func label(now: Date = Date()) -> String {
            switch self {
            case .active(let until):
                guard let until else { return "sempre attiva" }
                return "fino alle \(Self.hhmm(until))"
            case .upcoming(let at):
                let cal = Calendar(identifier: .gregorian)
                let mins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
                let delta = max(1, at - mins)
                return delta == 1 ? "tra 1 min" : "tra \(delta) min"
            }
        }
        private static func hhmm(_ m: Int) -> String {
            String(format: "%02d:%02d", m / 60, m % 60)
        }
    }

    let id = UUID()
    let name: String
    let city: String
    let polygon: [CLLocationCoordinate2D]
    let state: State

    /// Il punto cade dentro questa zona? Serve a capire se un parcheggio
    /// è dentro la ZTL — per non consigliarlo mentre la zona è in vigore.
    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) *
                   (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

actor ZTLService {
    static let shared = ZTLService()

    private var cache: [(date: Date, center: CLLocationCoordinate2D, zones: [ZTLZone])] = []

    /// Zone rilevanti attorno a un punto. Cache 10 minuti: lo stato di una
    /// ZTL invecchia in fretta, un dato vecchio direbbe l'orario sbagliato.
    func zones(near center: CLLocationCoordinate2D, radius: Double) async -> [ZTLZone] {
        let now = Date()
        if let hit = cache.first(where: {
            now.timeIntervalSince($0.date) < 600 &&
            CLLocation(latitude: $0.center.latitude, longitude: $0.center.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) < 300
        }) {
            return hit.zones
        }

        var comps = URLComponents(
            url: BackendConfig.baseURL.appendingPathComponent("v1/ztl"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(center.latitude)),
            URLQueryItem(name: "lon", value: String(center.longitude)),
            URLQueryItem(name: "r", value: String(Int(radius)))
        ]
        guard let url = comps?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(BackendConfig.appSecret, forHTTPHeaderField: "x-witp-app")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["zones"] as? [[String: Any]]
            else { return [] }

            var zones: [ZTLZone] = []
            for z in raw {
                guard let name = z["nome"] as? String,
                      let coords = z["poligono"] as? [[Double]], coords.count >= 4
                else { continue }
                // Il backend manda [lon, lat] (ordine GeoJSON)
                let polygon = coords.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count == 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
                guard polygon.count >= 4 else { continue }

                let state: ZTLZone.State
                if (z["stato"] as? String) == "attiva" {
                    state = .active(until: z["fino"] as? Int)
                } else if let at = z["alle"] as? Int {
                    state = .upcoming(at: at)
                } else { continue }

                zones.append(ZTLZone(
                    name: name,
                    city: (z["citta"] as? String) ?? "",
                    polygon: polygon,
                    state: state
                ))
            }
            cache.append((date: now, center: center, zones: zones))
            if cache.count > 8 { cache.removeFirst(cache.count - 8) }
            return zones
        } catch {
            return []   // rete assente: nessuna ZTL mostrata, mai un dato inventato
        }
    }
}
