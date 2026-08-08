//
//  SessionStore.swift
//  WITP
//
//  Persistenza delle sessioni di parcheggio in UserDefaults (JSON).
//  In produzione: CloudKit sync.
//

import Foundation
import Combine
import CoreLocation
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class SessionStore: ObservableObject {

    /// Istanza condivisa: la usano l'app e gli App Intents (Siri).
    static let shared = SessionStore()


    @Published var sessions: [ParkingSession] = []
    private let key = "witp.sessions.v1"

    #if canImport(ActivityKit)
    private var liveActivity: Activity<ParkingActivityAttributes>?
    #endif

    init() { load() }

    var active: ParkingSession? {
        sessions.first { $0.isActive }
    }

    func startSession(
        coordinate: CLLocationCoordinate2D,
        zoneType: ParkingZoneType,
        durationMinutes: Int?,
        plate: String = "",
        notes: String = ""
    ) {
        // Chiudi eventuale sessione attiva
        sessions = sessions.map { s in
            var s = s
            s.isActive = false
            return s
        }
        let session = ParkingSession(
            id: UUID(),
            coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
            zoneType: zoneType,
            startedAt: Date(),
            durationMinutes: durationMinutes,
            notes: notes,
            plate: plate,
            isActive: true
        )
        sessions.insert(session, at: 0)
        save()
        startLiveActivity(for: session)
        scheduleNotifications(for: session)
    }

    func endActiveSession() {
        guard let idx = sessions.firstIndex(where: { $0.isActive }) else { return }
        sessions[idx].isActive = false
        save()
        endLiveActivity()
        cancelNotifications()
    }

    // MARK: - Notifiche di sosta (piccole, utili, alla Apple Watch)

    private let notificationIDs = ["witp.sosta.warn", "witp.sosta.end", "witp.sosta.checkin"]

    private func scheduleNotifications(for session: ParkingSession) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let street = session.notes.isEmpty ? "la tua sosta" : session.notes

        func add(id: String, title: String, body: String, at date: Date) {
            guard date > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }

        if let end = session.endDate {
            if end.timeIntervalSince(session.startedAt) >= 15 * 60 {
                add(id: "witp.sosta.warn",
                    title: "Sosta in scadenza",
                    body: "\(street.prefix(1).uppercased() + street.dropFirst()): mancano 10 minuti.",
                    at: end.addingTimeInterval(-600))
            }
            add(id: "witp.sosta.end",
                title: "Sosta scaduta",
                body: "Il tempo per \(street) è finito. Corri o rinnova!",
                at: end)
        } else {
            // Sosta senza scadenza: un check-in gentile dopo un'ora e mezza.
            add(id: "witp.sosta.checkin",
                title: "Sosta ancora aperta",
                body: "Sei in sosta da un'ora e mezza. Tutto ok? Se sei ripartito, chiudila.",
                at: session.startedAt.addingTimeInterval(90 * 60))
        }
    }

    private func cancelNotifications() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: notificationIDs)
    }

    // MARK: - Live Activity (Dynamic Island + Lock Screen)

    private func startLiveActivity(for session: ParkingSession) {
        #if canImport(ActivityKit)
        endLiveActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = ParkingActivityAttributes(
            streetName: session.notes.isEmpty ? "Sosta attiva" : session.notes,
            zoneLabel: session.zoneType.label
        )
        let end = session.durationMinutes.map { session.startedAt.addingTimeInterval(Double($0) * 60) }
        let state = ParkingActivityAttributes.ContentState(endDate: end, startedAt: session.startedAt)
        liveActivity = try? Activity.request(attributes: attrs,
                                             content: .init(state: state, staleDate: nil))
        #endif
    }

    private func endLiveActivity() {
        #if canImport(ActivityKit)
        guard let activity = liveActivity else { return }
        liveActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    func remove(_ session: ParkingSession) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ParkingSession].self, from: data)
        else { return }
        sessions = decoded
    }
}
