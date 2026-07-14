//
//  ClaudeReasoner.swift
//  WITP
//
//  Client del backend WITP (Cloudflare Worker su api.whereistheparking.com).
//  La chiave Anthropic NON esiste in questa app: vive solo sul server.
//  L'app invia gli spot + la ricevuta firmata StoreKit 2; il server verifica
//  l'abbonamento, sceglie il modello (Haiku per Premium, Sonnet per Turbo)
//  e restituisce il verdetto. Qualsiasi errore → nil, si usa il modello locale.
//

import Foundation

// MARK: - Config backend

enum BackendConfig {

    /// Segreto condiviso con il Worker (stesso valore di `WITP_APP_SECRET`).
    /// Non è una chiave API: serve solo a scartare il traffico non-app.
    static let appSecret = "INCOLLA_QUI_WITP_APP_SECRET"

    static var baseURL: URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "witp.backend.url"),
           let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://api.whereistheparking.com")!
    }

    /// UUID anonimo del dispositivo (solo rate-limit, nessun tracking).
    static var deviceID: String {
        let key = "witp.device.id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

// MARK: - Output

struct ClaudeInsight {
    let summary: String                                   // 1-2 frasi in italiano
    let bestSpotID: UUID?
    let modelLabel: String                                // "Claude Haiku" / "Claude Sonnet"
    let adjustments: [UUID: (probability: Double, reason: String)]
}

// MARK: - Reasoner

final class ClaudeReasoner {

    static let shared = ClaudeReasoner()
    private init() {}

    /// Chiede al backend di raffinare le probabilità e scegliere il migliore.
    /// `jws` è la ricevuta firmata dell'abbonamento (StoreKit 2).
    /// Ritorna nil in caso di qualunque problema: mai bloccante.
    func analyze(spots: [ParkingSpot], tier: SubscriptionTier, jws: String?,
                 timeout: TimeInterval = 26) async -> ClaudeInsight? {
        let promo = SubscriptionManager.shared.validPromoToken
        guard tier != .free, !spots.isEmpty,
              (jws?.isEmpty == false) || promo != nil else { return nil }

        let candidates = Array(spots.prefix(12))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"

        let items: [[String: Any]] = candidates.map { s in
            [
                "id": s.id.uuidString,
                "nome": s.streetName,
                "tipo": s.zoneType.label,
                "stalli": s.stallCount,
                "distanza_m": Int(s.distanceFromUser),
                "probabilita_locale": (s.availability * 100).rounded() / 100,
                "motivi_locali": Array(s.availabilityReasoning.prefix(3))
            ]
        }

        var body: [String: Any] = [
            "context": formatter.string(from: Date()),
            "spots": items
        ]
        if let jws, !jws.isEmpty { body["jws"] = jws }
        if let promo { body["promo"] = promo }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: BackendConfig.baseURL.appendingPathComponent("v1/reason"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(BackendConfig.appSecret, forHTTPHeaderField: "x-witp-app")
        request.setValue(BackendConfig.deviceID, forHTTPHeaderField: "x-witp-device")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("⚠️ Backend HTTP \(code) — uso il modello locale")
                return nil
            }
            return parse(data)
        } catch {
            print("⚠️ Backend non raggiungibile (\(error.localizedDescription)) — modello locale")
            return nil
        }
    }

    // MARK: - Parsing

    private struct Verdict: Decodable {
        struct Adjustment: Decodable {
            let id: String
            let probability: Double
            let reason: String
        }
        let summary: String
        let best_id: String?
        let spots: [Adjustment]
        let model: String
    }

    private func parse(_ data: Data) -> ClaudeInsight? {
        guard let verdict = try? JSONDecoder().decode(Verdict.self, from: data) else { return nil }

        var adjustments: [UUID: (Double, String)] = [:]
        for adj in verdict.spots {
            guard let uuid = UUID(uuidString: adj.id) else { continue }
            adjustments[uuid] = (max(0.02, min(0.99, adj.probability)), adj.reason)
        }
        guard !adjustments.isEmpty else { return nil }

        return ClaudeInsight(
            summary: verdict.summary,
            bestSpotID: verdict.best_id.flatMap(UUID.init(uuidString:)),
            modelLabel: verdict.model,
            adjustments: adjustments
        )
    }
}
