//
//  WITPApp.swift
//  WITP — Where Is The Parking
//  By D.S. — 2026
//

import SwiftUI
import UIKit
import CarPlay

/// Collega la scena CarPlay al suo delegate IN CODICE.
///
/// Con il ciclo di vita SwiftUI, la sola dichiarazione nell'Info.plist
/// spesso non basta: iOS crea la scena CarPlay con il delegate di
/// default, che non implementa i metodi del ciclo di vita CarPlay e
/// l'app viene terminata con
/// "Application does not implement CarPlay template application
///  lifecycle methods in its scene delegate".
///
/// Indicando qui la classe direttamente, non si dipende più dalla
/// risoluzione del nome scritto nel plist.
final class WITPAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {

        if connectingSceneSession.role == UISceneSession.Role.carTemplateApplication {
            let config = UISceneConfiguration(name: "WITP-CarPlay",
                                              sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        // Tutto il resto (la normale finestra dell'app) resta a SwiftUI.
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

@main
struct WITPApp: App {

    @UIApplicationDelegateAdaptor(WITPAppDelegate.self) private var appDelegate

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
