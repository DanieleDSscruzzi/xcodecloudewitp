//
//  WITPApp.swift
//  WITP — Where Is The Parking
//  By D.S. — 2026
//

import SwiftUI

@main
struct WITPApp: App {

    @StateObject private var locationManager = LocationManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var parkingEngine = ParkingEngine.shared
    @StateObject private var sessionStore = SessionStore.shared
    @StateObject private var languageStore = LanguageStore.shared

    var body: some Scene {
        WindowGroup {
            SplashCoordinator()
                .environmentObject(locationManager)
                .environmentObject(subscriptionManager)
                .environmentObject(parkingEngine)
                .environmentObject(sessionStore)
                .environmentObject(languageStore)
                .environment(\.locale, languageStore.localeOverride ?? Locale.current)
                .id(languageStore.raw)
                .preferredColorScheme(.dark)
                .task {
                    await subscriptionManager.loadProducts()
                    await subscriptionManager.refreshEntitlements()
                    // La posizione si chiede nel momento giusto:
                    // onboarding o prima ricerca (mai a freddo all'avvio).
                }
        }
    }
}
