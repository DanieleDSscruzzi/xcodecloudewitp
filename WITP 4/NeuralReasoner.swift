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
    /// nil se il modello on-device non è disponibile o non risponde.
    func quickPick(spots: [ParkingSpot]) async -> (index: Int, reason: String)? {
        guard !spots.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await foundationPick(spots: spots)
        }
        #endif
        return nil
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
