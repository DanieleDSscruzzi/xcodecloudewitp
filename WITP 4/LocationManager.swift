//
//  LocationManager.swift
//  WITP
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// Istanza condivisa: la usano l'app e gli App Intents (Siri).
    static let shared = LocationManager()


    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// Una posizione, adesso (per Siri): prima l'ultima nota, poi il fix
    /// di sistema in cache se fresco, poi una richiesta singola con attesa.
    /// Nota iOS: con permesso "Mentre usi l'app" il GPS in background non
    /// consegna nulla — per questo gli intent che servono la posizione
    /// aprono l'app (openAppWhenRun = true).
    func oneShot(timeout: TimeInterval = 6) async -> CLLocationCoordinate2D? {
        if let c = currentLocation { return c }
        if let cached = manager.location,
           Date().timeIntervalSince(cached.timestamp) < 120 {
            currentLocation = cached.coordinate
            return cached.coordinate
        }
        requestAuthorization()
        manager.requestLocation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = currentLocation { return c }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return currentLocation ?? manager.location?.coordinate
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.currentLocation = coord
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // requestLocation() lo richiede: fallimento silenzioso, riproverà.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }
}
