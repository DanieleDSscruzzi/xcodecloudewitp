//
//  NeuralReasoner.swift
//  WITP — Ultra+: il primo verdetto lo dà il chip.
//
//  Usa il framework Foundation Models di iOS 26 (il modello Apple che gira
//  sul Neural Engine): niente rete, risposta in frazioni di secondo.
//  Se il dispositivo non lo supporta → nil, e si prosegue col modello
//  locale + Claude. Mai bloccante, come tutto il resto.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

final class NeuralReasoner {

    static let shared = NeuralReasoner()
    private init() {}

    /// Verdetto lampo: indice del parcheggio migliore + motivo breve.
    /// Foundation Models (Neural Engine) se disponibile; altrimenti
    /// l'euristica WITP. Con almeno uno spot, NON torna mai nil:
    /// l'app dà sempre una risposta, anche offline.
    func quickPick(spots: [ParkingSpot]) async -> (index: Int, reason: String, onDevice: Bool)? {
        guard !spots.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let fm = await foundationPick(spots: spots) {
                return (fm.index, fm.reason, true)
            }
        }
        #endif
        return heuristicPick(spots: spots)
    }

    /// Selezione deterministica: probabilità di posto libero pesata con la
    /// distanza a piedi, bonus per la sosta gratuita, malus per i posti
    /// disabili (mai proposti come scelta "generica").
    func heuristicPick(spots: [ParkingSpot]) -> (index: Int, reason: String, onDevice: Bool)? {
        guard !spots.isEmpty else { return nil }
        var bestIdx = 0
        var bestScore = -Double.infinity
        for (i, s) in spots.enumerated() {
            var score = s.availability * 100
            score -= Double(s.distanceFromUser) / 18.0     // ≈5,5 punti ogni 100 m
            if s.zoneType == .free { score += 8 }
            if s.zoneType == .disabled { score -= 40 }
            if s.stallCount > 25 { score += 4 }            // lotti grandi = più ricambio
            if score > bestScore { bestScore = score; bestIdx = i }
        }
        let s = spots[bestIdx]
        var why = "\(Int(s.availability * 100))% libero a \(Int(s.distanceFromUser)) m"
        if s.zoneType == .free { why += ", gratis" }
        else if s.zoneType == .paid { why += ", strisce blu" }
        else if s.zoneType == .reserved { why += ", residenti" }
        return (bestIdx, why, false)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func foundationPick(spots: [ParkingSpot]) async -> (index: Int, reason: String)? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let candidates = Array(spots.prefix(8))
        let list = candidates.enumerated().map { i, s in
            "\(i)) \(s.streetName) — \(Int(s.availability * 100))% libero · \(Int(s.distanceFromUser)) m · \(s.zoneType.label)"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions:
            "Sei il selettore parcheggi di WITP. Scegli il migliore bilanciando probabilità di posto libero e distanza a piedi. Rispondi in UNA sola riga, formato esatto: indice|motivo in italiano (max 60 caratteri). Nessun altro testo.")

        do {
            let response = try await session.respond(to: "Parcheggi:\n\(list)\nRisposta:")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let idx = Int(parts[0].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)),
                  idx >= 0, idx < candidates.count else { return nil }
            let reason = parts[1].trimmingCharacters(in: .whitespaces)
            guard !reason.isEmpty else { return nil }
            return (idx, String(reason.prefix(80)))
        } catch {
            return nil
        }
    }
    #endif
}
