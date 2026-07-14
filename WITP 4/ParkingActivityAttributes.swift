//
//  ParkingActivityAttributes.swift
//  WITP — contratto della Live Activity (Dynamic Island + Lock Screen).
//
//  ⚠️ Questo file deve appartenere a ENTRAMBI i target: l'app (che avvia
//  l'attività) e l'estensione WITPWidgets (che la disegna).
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit

struct ParkingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date?     // nil = sosta senza scadenza (conta in avanti)
        var startedAt: Date
    }
    var streetName: String
    var zoneLabel: String
}
#endif
