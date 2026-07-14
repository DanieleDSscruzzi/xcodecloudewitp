//
//  Models.swift
//  WITP
//

import Foundation
import CoreLocation
import SwiftUI

// MARK: - Subscription Tier

enum SubscriptionTier: String, Codable, CaseIterable, Identifiable {
    case free, premium, turbo, ultra, ultraPlus

    var id: String { rawValue }

    /// Ordine di potenza (per upgrade/downgrade e confronti).
    var rank: Int {
        switch self {
        case .free: return 0
        case .premium: return 1
        case .turbo: return 2
        case .ultra: return 3
        case .ultraPlus: return 4
        }
    }

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .premium: return "Premium"
        case .turbo: return "Turbo"
        case .ultra: return "Ultra"
        case .ultraPlus: return "Ultra+"
        }
    }

    var monthlyPriceLabel: String {
        switch self {
        case .free: return "€0"
        case .premium: return "€6,99"
        case .turbo: return "€12,99"
        case .ultra: return "€19,99"
        case .ultraPlus: return "€49,99"
        }
    }

    var searchRadius: Double {
        switch self {
        case .free: return 400
        case .premium: return 1000
        case .turbo: return 1500
        case .ultra: return 2000
        case .ultraPlus: return 2500
        }
    }

    var maxStreets: Int {
        switch self {
        case .free: return 6
        case .premium: return 15
        case .turbo: return 30
        case .ultra: return 40
        case .ultraPlus: return 50
        }
    }

    var accentColor: Color {
        switch self {
        case .free: return .gray
        case .premium: return .blue
        case .turbo: return .orange
        case .ultra: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .ultraPlus: return Color(red: 1.00, green: 0.22, blue: 0.37)
        }
    }

    /// I piani veloci tengono i dati già pronti intorno a te (prefetch):
    /// è così che una risposta in 3 o 1 secondi diventa fisicamente onesta.
    var prefetches: Bool { rank >= SubscriptionTier.ultra.rank }

    /// Ultra+: il primo ragionamento gira SUL CHIP (Neural Engine,
    /// framework Foundation Models di iOS 26). Claude rifinisce dopo.
    var usesOnDeviceReasoning: Bool { self == .ultraPlus }

    /// Il prodotto è la velocità: tempo massimo entro cui arriva LA risposta.
    /// Il modello locale la garantisce sempre entro il budget; se Claude
    /// impiega di più, rifinisce la risposta già mostrata (mai attese oltre).
    ///
    var answerBudget: TimeInterval {
        switch self {
        case .free:      return 20
        case .premium:   return 10
        case .turbo:     return 5
        case .ultra:     return 3
        case .ultraPlus: return 1
        }
    }
}

// MARK: - Parking Zone Type

enum ParkingZoneType: String, Codable, CaseIterable {
    case free, paid, reserved, disabled

    var color: Color {
        switch self {
        case .free:     return .white
        case .paid:     return Color(red: 0.20, green: 0.55, blue: 1.00)
        case .reserved: return Color(red: 1.00, green: 0.85, blue: 0.20)
        case .disabled: return Color(red: 0.95, green: 0.30, blue: 0.30)
        }
    }

    var label: String {
        switch self {
        case .free: return "Libero"
        case .paid: return "A pagamento"
        case .reserved: return "Residenti"
        case .disabled: return "Disabili"
        }
    }

    var symbol: String {
        switch self {
        case .free: return "p.square"
        case .paid: return "eurosign.square"
        case .reserved: return "exclamationmark.square"
        case .disabled: return "figure.roll"
        }
    }
}

// MARK: - Parking Stripe (UNO stallo)

struct ParkingStripe: Identifiable, Hashable {
    let id = UUID()
    let polygon: [CLLocationCoordinate2D]   // 4 vertici
    let center: CLLocationCoordinate2D
    let zoneType: ParkingZoneType

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ParkingStripe, rhs: ParkingStripe) -> Bool { lhs.id == rhs.id }
}

// MARK: - Parking Spot (un gruppo di strisce su una strada)

struct ParkingSpot: Identifiable, Hashable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D    // centro del gruppo (per pin)
    let streetName: String
    let zoneType: ParkingZoneType
    let stripes: [ParkingStripe]              // singoli stalli
    let confidence: Double
    var distanceFromUser: Double   // ricalcolata quando la cache serve un nuovo centro              // metri
    var availability: Double = 0.5            // 0...1 probabilità libero adesso
    var availabilityReasoning: [String] = []  // motivi per UI
    var stallCountOverride: Int? = nil        // multipiano/interrati: conteggio senza stalli disegnati

    var stallCount: Int { stallCountOverride ?? stripes.count }

    /// Livello sintetico di disponibilità per pin colorato
    var availabilityLevel: AvailabilityLevel {
        switch availability {
        case 0.75...:    return .high
        case 0.45..<0.75: return .medium
        default:         return .low
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ParkingSpot, rhs: ParkingSpot) -> Bool { lhs.id == rhs.id }
}

enum AvailabilityLevel {
    case high, medium, low

    var color: Color {
        switch self {
        case .high:   return Color(red: 0.30, green: 0.90, blue: 0.50)  // verde
        case .medium: return Color(red: 1.00, green: 0.75, blue: 0.20)  // giallo
        case .low:    return Color(red: 1.00, green: 0.30, blue: 0.35)  // rosso
        }
    }

    var label: String {
        switch self {
        case .high:   return "Alta probabilità"
        case .medium: return "Media probabilità"
        case .low:    return "Bassa probabilità"
        }
    }

    var emoji: String {
        switch self {
        case .high:   return "🟢"
        case .medium: return "🟡"
        case .low:    return "🔴"
        }
    }
}

// MARK: - Parking Session

struct ParkingSession: Identifiable, Codable {
    let id: UUID
    var coordinate: Coordinate
    var zoneType: ParkingZoneType
    var startedAt: Date
    var durationMinutes: Int?
    var notes: String = ""
    var plate: String = ""
    var isActive: Bool = true

    struct Coordinate: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        var clLocation: CLLocationCoordinate2D {
            .init(latitude: latitude, longitude: longitude)
        }
    }

    var endDate: Date? {
        guard let d = durationMinutes else { return nil }
        return startedAt.addingTimeInterval(TimeInterval(d) * 60)
    }

    var remainingSeconds: TimeInterval? {
        guard let end = endDate else { return nil }
        return max(0, end.timeIntervalSinceNow)
    }
}

// MARK: - Analysis Result

struct ParkingScanResult {
    let startedAt: Date
    let finishedAt: Date
    let spots: [ParkingSpot]
    let tier: SubscriptionTier
    let center: CLLocationCoordinate2D

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    var totalStalls: Int { spots.map(\.stallCount).reduce(0, +) }
}
