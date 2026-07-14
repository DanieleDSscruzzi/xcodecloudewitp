//
//  AvailabilityPredictor.swift
//  WITP
//
//  Calcola probabilità che un parcheggio sia libero (0...1).
//
//  Modello matematico deterministico (Free tier):
//  La probabilità è una funzione di:
//   - Ora del giorno (curva oraria tipica)
//   - Giorno settimana (lun-gio diverso da sab/dom)
//   - Tipo zona (residenziale / commerciale / centro / ospedale / scuola)
//   - Capacità totale (più stalli = più chance)
//   - Distanza dal centro (centro = più affollato)
//   - Feedback utente locale (ricorda i parcheggi che hai testato)
//

import Foundation
import CoreLocation

enum ZoneCategory: String {
    case residential   // sotto casa, condomini
    case commercial    // negozi, ristoranti
    case central       // centro storico
    case hospital      // ospedale
    case school        // scuola
    case office        // uffici
    case leisure       // parchi, cinema, teatri
    case generic
}

struct AvailabilityPrediction {
    let probability: Double          // 0...1
    let reasoning: [String]          // motivi per UI
    let category: ZoneCategory
    let timestamp: Date
}

@MainActor
final class AvailabilityPredictor {

    static let shared = AvailabilityPredictor()
    private init() {}

    // MARK: - API pubblica

    /// Calcola la probabilità che ALMENO uno stallo sia libero adesso.
    func predict(for spot: ParkingSpot, at date: Date = Date()) -> AvailabilityPrediction {

        let category = inferCategory(spot: spot)
        let cal = Calendar(identifier: .gregorian)
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let weekday = cal.component(.weekday, from: date)  // 1=Domenica, 7=Sabato
        let timeFloat = Double(hour) + Double(minute) / 60.0

        var reasoning: [String] = []

        // 1. Probabilità base dalla curva oraria della categoria
        let hourlyProb = hourlyOccupancyCurve(category: category, time: timeFloat, weekday: weekday)
        var prob = 1.0 - hourlyProb   // converti occupazione → disponibilità

        reasoning.append(timeReasoning(category: category, hour: hour, weekday: weekday))

        // 2. Bonus capacità: parcheggi grandi hanno sempre più probabilità
        //    Modello: P(almeno uno libero) = 1 - (occupazione)^N
        //    Con N=stalli, anche 80% occupazione su 100 stalli → ~100% trovi posto
        let n = max(1, spot.stallCount)
        let occupancyRate = hourlyProb
        let probAtLeastOneFree = 1 - pow(occupancyRate, Double(n))

        // Combina: media pesata 30% prob singolo stallo + 70% prob almeno-uno
        prob = prob * 0.30 + probAtLeastOneFree * 0.70

        if n >= 50 {
            reasoning.append("Parcheggio grande (\(n) stalli) → quasi sempre c'è posto")
        } else if n <= 5 {
            reasoning.append("Solo \(n) stalli → bassa probabilità anche fuori orari di punta")
        }

        // 3. Modulazione per distanza dal centro città
        //    Centro = sempre più pieno. Periferia = sempre più libero.
        let centralityPenalty = centralityFactor(distance: spot.distanceFromUser)
        prob *= (1.0 - centralityPenalty * 0.15)

        if centralityPenalty > 0.7 {
            reasoning.append("Zona centrale → sempre più richiesta")
        }

        // 4. Tipo zona (paid vs free vs reserved)
        switch spot.zoneType {
        case .reserved:
            prob *= 0.55   // riservato → spesso occupato dai residenti
            reasoning.append("Stalli riservati: meno probabilità per non residenti")
        case .disabled:
            prob *= 0.40   // disabili → quasi sempre vuoti ma non ti riguarda se non hai contrassegno
            reasoning.append("Stalli disabili: solo con contrassegno")
        case .paid:
            prob *= 1.05   // a pagamento → la gente evita di tenerli a lungo
        case .free:
            prob *= 0.92   // gratuito → tendenzialmente più pieno
        }

        // 5. Feedback utente locale (memoria sui parcheggi già testati)
        if let userBias = userFeedbackBias(for: spot) {
            prob = prob * 0.6 + userBias * 0.4
            reasoning.append("Storia tue verifiche: \(Int(userBias * 100))% libero")
        }

        // Clamp
        prob = max(0.05, min(0.99, prob))

        return AvailabilityPrediction(
            probability: prob,
            reasoning: reasoning,
            category: category,
            timestamp: date
        )
    }

    // MARK: - Inferenza categoria zona

    private func inferCategory(spot: ParkingSpot) -> ZoneCategory {
        // Mondiale: parole chiave IT / EN / FR (fallback: generic).
        let n = spot.streetName.lowercased()
        func any(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if any(["ospedale", "hospital", "clinic", "clinica", "hôpital", "pronto soccorso", "emergency"]) { return .hospital }
        if any(["scuola", "school", "liceo", "istituto", "universit", "école", "college", "campus"]) { return .school }
        if any(["centro", "piazza", "duomo", "comune", "downtown", "city center", "centre-ville", "plaza", "square", "mairie", "municipio"]) { return .central }
        if any(["teatro", "cinema", "museo", "museum", "parco", "stadio", "stadium", "théâtre", "arena", "beach", "lido"]) { return .leisure }
        if any(["supermercato", "mercato", "market", "mall", "centro commerciale", "negoz", "shop", "store", "galerie"]) { return .commercial }
        if any(["ufficio", "office", "posta", "banca", "bank", "bureau", "business"]) { return .office }
        if spot.zoneType == .free && spot.distanceFromUser > 400 { return .residential }
        return .generic
    }

    // MARK: - Curva di occupazione oraria

    /// Restituisce occupazione media stimata (0...1) per (categoria, ora, giorno).
    /// Curve calibrate sul comportamento medio italiano.
    private func hourlyOccupancyCurve(category: ZoneCategory, time t: Double, weekday: Int) -> Double {

        let isWeekend = (weekday == 1 || weekday == 7)  // dom/sab

        switch category {

        case .residential:
            // Sotto casa: pieno la sera (rientro), parzialmente vuoto di giorno (gente al lavoro)
            // Ma anche di notte non è MAI tutto libero (non tutti escono di giorno)
            if isWeekend {
                // Weekend: gente più a casa
                return interpolate(t, points: [
                    (0, 0.85), (6, 0.85), (10, 0.78), (14, 0.75),
                    (18, 0.85), (22, 0.92), (24, 0.85)
                ])
            } else {
                // Feriale: lun-ven
                return interpolate(t, points: [
                    (0, 0.92), (6, 0.92), (8, 0.65),  // 8: gente esce per lavoro
                    (12, 0.55), (14, 0.62),
                    (18, 0.85), (20, 0.92), (24, 0.92)
                ])
            }

        case .commercial:
            // Negozi/ristoranti: vuoto la notte, pieno orari shopping/cena
            if isWeekend {
                return interpolate(t, points: [
                    (0, 0.10), (8, 0.20), (10, 0.65), (12, 0.85),
                    (15, 0.75), (17, 0.90), (20, 0.85), (23, 0.40), (24, 0.15)
                ])
            } else {
                return interpolate(t, points: [
                    (0, 0.08), (8, 0.30), (10, 0.55), (12, 0.70),
                    (14, 0.50), (17, 0.75), (20, 0.65), (23, 0.30)
                ])
            }

        case .central:
            // Centro storico: sempre più richiesto, max ora di pranzo e sera weekend
            if isWeekend {
                return interpolate(t, points: [
                    (0, 0.30), (8, 0.40), (11, 0.85), (13, 0.95),
                    (15, 0.80), (18, 0.92), (21, 0.85), (24, 0.45)
                ])
            } else {
                return interpolate(t, points: [
                    (0, 0.25), (7, 0.50), (9, 0.85), (12, 0.90),
                    (14, 0.75), (17, 0.88), (20, 0.65), (24, 0.30)
                ])
            }

        case .hospital:
            // Ospedale: SEMPRE pieno, 24/7. Picco mattina (visite ambulatoriali)
            return interpolate(t, points: [
                (0, 0.78), (6, 0.82), (8, 0.95), (11, 0.98),
                (14, 0.90), (17, 0.85), (20, 0.80), (24, 0.78)
            ])

        case .school:
            // Scuola: pieno solo in orario scolastico (genitori che accompagnano)
            if isWeekend {
                return 0.10   // weekend = quasi vuoto
            }
            return interpolate(t, points: [
                (0, 0.08), (7, 0.30), (8, 0.92),    // ingresso
                (9, 0.30), (12, 0.80), (13, 0.85), (14, 0.40),  // uscita scuola elementare
                (16, 0.55), (17, 0.30), (24, 0.08)
            ])

        case .office:
            // Uffici: pieno orario ufficio lun-ven
            if isWeekend { return 0.15 }
            return interpolate(t, points: [
                (0, 0.10), (7, 0.30), (9, 0.85), (12, 0.65),
                (14, 0.85), (17, 0.75), (19, 0.30), (24, 0.10)
            ])

        case .leisure:
            // Cinema/teatro/parchi: weekend pomeriggio/sera
            if isWeekend {
                return interpolate(t, points: [
                    (0, 0.20), (10, 0.45), (14, 0.75), (17, 0.85),
                    (20, 0.92), (23, 0.60), (24, 0.30)
                ])
            } else {
                return interpolate(t, points: [
                    (0, 0.15), (10, 0.25), (17, 0.55), (20, 0.78),
                    (22, 0.65), (24, 0.20)
                ])
            }

        case .generic:
            // Curva standard
            if isWeekend {
                return interpolate(t, points: [
                    (0, 0.30), (8, 0.40), (12, 0.70), (15, 0.65),
                    (19, 0.75), (22, 0.55), (24, 0.35)
                ])
            } else {
                return interpolate(t, points: [
                    (0, 0.25), (8, 0.65), (12, 0.75), (14, 0.65),
                    (18, 0.78), (21, 0.55), (24, 0.30)
                ])
            }
        }
    }

    // MARK: - Interpolazione lineare tra punti orari

    private func interpolate(_ t: Double, points: [(Double, Double)]) -> Double {
        guard !points.isEmpty else { return 0.5 }
        if t <= points.first!.0 { return points.first!.1 }
        if t >= points.last!.0 { return points.last!.1 }

        for i in 1..<points.count {
            let (t1, v1) = points[i-1]
            let (t2, v2) = points[i]
            if t >= t1 && t <= t2 {
                let f = (t - t1) / (t2 - t1)
                return v1 + (v2 - v1) * f
            }
        }
        return 0.5
    }

    // MARK: - Centralità

    private func centralityFactor(distance: Double) -> Double {
        // Distanza dall'utente = proxy della distanza dal centro (utente di solito è in centro)
        // 0m = 100% centro, 1500m = 0% centro
        let normalized = max(0, min(1, 1 - distance / 1500))
        return normalized
    }

    // MARK: - Time reasoning string

    private func timeReasoning(category: ZoneCategory, hour: Int, weekday: Int) -> String {
        let isWeekend = (weekday == 1 || weekday == 7)
        let dayLabel = isWeekend ? "weekend" : "feriale"

        let timeOfDay: String
        switch hour {
        case 0..<6: timeOfDay = "notte fonda"
        case 6..<9: timeOfDay = "mattina presto"
        case 9..<12: timeOfDay = "metà mattina"
        case 12..<15: timeOfDay = "ora di pranzo"
        case 15..<18: timeOfDay = "pomeriggio"
        case 18..<21: timeOfDay = "sera"
        default: timeOfDay = "tarda sera"
        }

        let categoryDesc: String
        switch category {
        case .residential: categoryDesc = "zona residenziale"
        case .commercial:  categoryDesc = "zona commerciale"
        case .central:     categoryDesc = "centro città"
        case .hospital:    categoryDesc = "ospedale"
        case .school:      categoryDesc = "scuola"
        case .office:      categoryDesc = "uffici"
        case .leisure:     categoryDesc = "area svago"
        case .generic:     categoryDesc = "zona generica"
        }

        return "\(categoryDesc.capitalized), \(timeOfDay) \(dayLabel)"
    }

    // MARK: - Feedback utente locale

    /// Restituisce il bias dell'utente per questo spot (0...1) o nil se mai testato.
    private func userFeedbackBias(for spot: ParkingSpot) -> Double? {
        let key = feedbackKey(for: spot)
        let data = UserDefaults.standard.dictionary(forKey: "witp.feedbacks") as? [String: [String: Double]]
        guard let entry = data?[key] else { return nil }
        let positives = entry["positives"] ?? 0
        let total = entry["total"] ?? 0
        guard total > 0 else { return nil }
        return positives / total
    }

    /// Salva un feedback dell'utente: trovato libero (true) o pieno (false).
    func recordFeedback(for spot: ParkingSpot, foundFree: Bool) {
        let key = feedbackKey(for: spot)
        var data = UserDefaults.standard.dictionary(forKey: "witp.feedbacks") as? [String: [String: Double]] ?? [:]
        var entry = data[key] ?? ["positives": 0, "total": 0]
        if foundFree { entry["positives"] = (entry["positives"] ?? 0) + 1 }
        entry["total"] = (entry["total"] ?? 0) + 1
        data[key] = entry
        UserDefaults.standard.set(data, forKey: "witp.feedbacks")
    }

    private func feedbackKey(for spot: ParkingSpot) -> String {
        // Chiave stabile basata su coordinate arrotondate (stesso parcheggio = stessa chiave)
        let lat = round(spot.coordinate.latitude * 10000) / 10000
        let lon = round(spot.coordinate.longitude * 10000) / 10000
        return "\(lat),\(lon)"
    }
}
