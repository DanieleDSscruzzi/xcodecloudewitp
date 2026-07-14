//
//  WITPIntents.swift
//  WITP — Siri, con discorsi veri.
//
//  App Intents: alla guida parli, WITP risponde a voce. Siri chiede da sola
//  i parametri che mancano ("Per quanti minuti?") — la conversazione è
//  gestita dal sistema, i contenuti li mettiamo noi.
//

import AppIntents
import CoreLocation

// MARK: - Trova parcheggio (a voce, senza aprire l'app)

struct FindParkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Trova parcheggio"
    static let description = IntentDescription("Cerca il parcheggio migliore intorno a te e te lo dice a voce.")
    // Apre l'app: con permesso "Mentre usi l'app", il GPS in background
    // non consegna nulla. Siri parla comunque — zero tocchi.
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let loc = await LocationManager.shared.oneShot() else {
            return .result(dialog: "Non riesco a prendere la posizione. Controlla che WITP abbia il permesso in Impostazioni, Privacy, Posizione.")
        }
        let subs = SubscriptionManager.shared
        let best = await ParkingEngine.shared.scanAndAnswer(center: loc,
                                                            tier: subs.currentTier,
                                                            jws: subs.entitlementJWS)
        guard let best else {
            return .result(dialog: "Qui intorno non trovo parcheggi mappati. Prova ad avvicinarti al centro.")
        }
        let extra = ParkingEngine.shared.insight?.summary
            ?? best.availabilityReasoning.first ?? ""
        let text = "Il migliore è \(best.streetName): \(Int(best.availability * 100)) per cento di trovare posto, a \(Int(best.distanceFromUser)) metri. \(extra) Se vuoi, dì: portami al parcheggio."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Portami al parcheggio (apre le indicazioni)

struct NavigateToParkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Portami al parcheggio"
    static let description = IntentDescription("Apre le indicazioni verso il parcheggio migliore trovato.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(true, forKey: "witp.siri.navigate")
        return .result(dialog: "Ti porto al parcheggio migliore.")
    }
}

// MARK: - Avvia una sosta (Siri chiede la durata)

struct StartParkingSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Avvia sosta"
    static let description = IntentDescription("Avvia il timer della sosta: compare anche nella Dynamic Island.")
    static let openAppWhenRun: Bool = true   // serve la posizione → foreground

    @Parameter(title: "Minuti di sosta")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m: Int
        if let minutes { m = minutes }
        else { m = try await $minutes.requestValue("Per quanti minuti hai parcheggiato?") }
        guard m > 0, m <= 24 * 60 else {
            return .result(dialog: "La durata deve essere tra 1 minuto e 24 ore.")
        }

        let engine = ParkingEngine.shared
        let coord = await LocationManager.shared.oneShot() ?? engine.bestSpot?.coordinate
        guard let coord else {
            return .result(dialog: "Non riesco a capire dove sei: apri WITP e avvia la sosta da lì.")
        }
        let street = engine.bestSpot?.streetName ?? ""
        SessionStore.shared.startSession(coordinate: coord,
                                         zoneType: engine.bestSpot?.zoneType ?? .free,
                                         durationMinutes: m,
                                         notes: street)
        let end = Date().addingTimeInterval(Double(m) * 60)
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"; fmt.locale = Locale(identifier: "it_IT")
        return .result(dialog: IntentDialog(stringLiteral:
            "Sosta di \(m) minuti avviata\(street.isEmpty ? "" : " in \(street)"). Scade alle \(fmt.string(from: end)): la vedi nella Dynamic Island."))
    }
}

// MARK: - Termina la sosta

struct EndParkingSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Termina sosta"
    static let description = IntentDescription("Chiude la sosta attiva.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let active = SessionStore.shared.active else {
            return .result(dialog: "Non c'è nessuna sosta attiva.")
        }
        let elapsed = Int(Date().timeIntervalSince(active.startedAt) / 60)
        SessionStore.shared.endActiveSession()
        return .result(dialog: IntentDialog(stringLiteral: "Sosta terminata dopo \(max(1, elapsed)) minuti. Buon viaggio."))
    }
}

// MARK: - Quanto manca?

struct ParkingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Stato sosta"
    static let description = IntentDescription("Ti dice quanto manca alla fine della sosta.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let active = SessionStore.shared.active else {
            return .result(dialog: "Nessuna sosta attiva al momento.")
        }
        if let end = active.endDate {
            let remaining = Int(end.timeIntervalSinceNow / 60)
            if remaining <= 0 {
                return .result(dialog: "La sosta è scaduta! Corri o rinnovala.")
            }
            return .result(dialog: IntentDialog(stringLiteral: "Mancano \(remaining) minuti alla fine della sosta."))
        }
        let elapsed = Int(Date().timeIntervalSince(active.startedAt) / 60)
        return .result(dialog: IntentDialog(stringLiteral: "Sosta aperta da \(max(1, elapsed)) minuti, senza scadenza."))
    }
}

// MARK: - Dov'è la mia auto?

struct WhereIsMyCarIntent: AppIntent {
    static let title: LocalizedStringResource = "Dov'è la mia auto"
    static let description = IntentDescription("Apre le indicazioni a piedi fino all'ultima sosta.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SessionStore.shared.sessions.first != nil else {
            return .result(dialog: "Non ho ancora nessuna sosta registrata.")
        }
        UserDefaults.standard.set(true, forKey: "witp.siri.car")
        return .result(dialog: "Ti porto dalla tua auto.")
    }
}

// MARK: - Le frasi (Siri le impara da sole, senza configurazione)

struct WITPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindParkingIntent(), phrases: [
            "Trova parcheggio con \(.applicationName)",
            "Cerca parcheggio con \(.applicationName)",
            "Trovami un parcheggio con \(.applicationName)",
            "Dov'è il parcheggio su \(.applicationName)",
            "Dove parcheggio con \(.applicationName)",
            "C'è posto con \(.applicationName)",
            "Parcheggio libero con \(.applicationName)",
            "\(.applicationName), trova parcheggio",
            "\(.applicationName), dove parcheggio",
            "Find parking with \(.applicationName)"
        ], shortTitle: "Trova parcheggio", systemImageName: "parkingsign")

        AppShortcut(intent: NavigateToParkingIntent(), phrases: [
            "Portami al parcheggio con \(.applicationName)",
            "Vai al parcheggio con \(.applicationName)",
            "Indicazioni per il parcheggio con \(.applicationName)",
            "\(.applicationName), portami al parcheggio",
            "\(.applicationName), portami lì",
            "Take me to the parking with \(.applicationName)"
        ], shortTitle: "Portami lì", systemImageName: "arrow.triangle.turn.up.right.diamond.fill")

        AppShortcut(intent: StartParkingSessionIntent(), phrases: [
            "Avvia una sosta con \(.applicationName)",
            "Ho parcheggiato con \(.applicationName)",
            "Inizia la sosta con \(.applicationName)",
            "Metti il timer del parcheggio con \(.applicationName)",
            "\(.applicationName), ho parcheggiato",
            "\(.applicationName), avvia la sosta",
            "Start parking with \(.applicationName)"
        ], shortTitle: "Avvia sosta", systemImageName: "clock.fill")

        AppShortcut(intent: EndParkingSessionIntent(), phrases: [
            "Termina la sosta con \(.applicationName)",
            "Fine sosta con \(.applicationName)",
            "Sto ripartendo con \(.applicationName)",
            "\(.applicationName), termina la sosta",
            "Stop parking with \(.applicationName)"
        ], shortTitle: "Termina sosta", systemImageName: "checkmark.circle.fill")

        AppShortcut(intent: ParkingStatusIntent(), phrases: [
            "Quanto manca alla sosta con \(.applicationName)",
            "Quanto tempo ho con \(.applicationName)",
            "Stato della sosta con \(.applicationName)",
            "\(.applicationName), quanto manca",
            "\(.applicationName), quanto tempo mi resta"
        ], shortTitle: "Quanto manca", systemImageName: "timer")

        AppShortcut(intent: WhereIsMyCarIntent(), phrases: [
            "Dov'è la mia auto con \(.applicationName)",
            "Dove ho parcheggiato con \(.applicationName)",
            "Trova la mia macchina con \(.applicationName)",
            "\(.applicationName), dov'è la macchina",
            "\(.applicationName), dove ho parcheggiato",
            "Where is my car with \(.applicationName)"
        ], shortTitle: "Dov'è l'auto", systemImageName: "car.fill")
    }
}
