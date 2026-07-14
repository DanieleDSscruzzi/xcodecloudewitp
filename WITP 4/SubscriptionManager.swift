//
//  SubscriptionManager.swift
//  WITP
//
//  StoreKit 2 — gestione abbonamenti Free / Premium €6,99 / Turbo €12,99.
//

import Foundation
import StoreKit
import Combine

final class SubscriptionManager: ObservableObject {

    /// Istanza condivisa: la usano l'app e gli App Intents (Siri).
    static let shared = SubscriptionManager()


    @Published var currentTier: SubscriptionTier = .free
    /// Ricevuta firmata (JWS) dell'entitlement attivo — inviata al backend
    /// che verifica l'abbonamento e sceglie il modello. Mai nil se abbonato.
    @Published var entitlementJWS: String?
    @Published var products: [Product] = []
    @Published var purchaseInProgress: Bool = false
    @Published var lastError: String?
    /// Cambio piano programmato al prossimo rinnovo (regola App Store:
    /// i downgrade non sono mai immediati). nil = nessun cambio in vista.
    @Published var pendingRenewalTier: SubscriptionTier?

    /// Codice sviluppatore attivo (Ultra+ a tempo): scadenza del grant.
    @Published var promoExpiry: Date?

    /// Token firmato dal server, valido e non scaduto (per il reasoner).
    var validPromoToken: String? {
        guard let exp = promoExpiry, exp > Date(),
              let tok = UserDefaults.standard.string(forKey: "witp.promo.token")
        else { return nil }
        return tok
    }

    private let productIDs: Set<String> = [
        "cobianchi.WITP.premium.Claude2",
        "cobianchi.WITP.turbo.Claude2",
        "cobianchi.WITP.ultra.Claude2",
        "cobianchi.WITP.ultraplus.Claude2"
    ]

    /// Mappa productID → tier (attenzione: "ultraplus" contiene "ultra",
    /// quindi l'ordine dei controlli conta).
    static func tier(forProductID id: String) -> SubscriptionTier {
        if id.contains("ultraplus") { return .ultraPlus }
        if id.contains("ultra")     { return .ultra }
        if id.contains("turbo")     { return .turbo }
        if id.contains("premium")   { return .premium }
        return .free
    }

    static func productID(for tier: SubscriptionTier) -> String? {
        switch tier {
        case .free:      return nil
        case .premium:   return "cobianchi.WITP.premium.Claude2"
        case .turbo:     return "cobianchi.WITP.turbo.Claude2"
        case .ultra:     return "cobianchi.WITP.ultra.Claude2"
        case .ultraPlus: return "cobianchi.WITP.ultraplus.Claude2"
        }
    }

    private var updateListenerTask: Task<Void, Never>?

    init() {
        updateListenerTask = listenForTransactions()
    }

    deinit { updateListenerTask?.cancel() }

    // MARK: - Load

    @MainActor
    func loadProducts() async {
        do {
            print("🛒 Carico prodotti per IDs: \(productIDs)")
            let products = try await Product.products(for: productIDs)
            self.products = products.sorted { $0.price < $1.price }
            print("✅ Prodotti caricati: \(products.count)")
            for p in products {
                print("   • \(p.id) — \(p.displayName) — \(p.displayPrice)")
            }
            if products.isEmpty {
                print("⚠️ Nessun prodotto trovato. Verifica che Products.storekit sia selezionato in Edit Scheme.")
            }
        } catch {
            print("❌ Errore caricamento prodotti: \(error)")
            lastError = "Impossibile caricare i prodotti: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    @MainActor
    func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
            case .userCancelled:
                break
            case .pending:
                lastError = "Acquisto in sospeso."
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Entitlements

    @MainActor
    func refreshEntitlements() async {
        var best: SubscriptionTier = .free
        var jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let t = Self.tier(forProductID: transaction.productID)
            if t.rank > best.rank {
                best = t
                jws = result.jwsRepresentation
            }
        }
        // Codice sviluppatore: se attivo, vince il tier più alto.
        let promoExp = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "witp.promo.expiry"))
        if promoExp > Date(), UserDefaults.standard.string(forKey: "witp.promo.token") != nil {
            promoExpiry = promoExp
            if SubscriptionTier.ultraPlus.rank > best.rank { best = .ultraPlus }
        } else {
            promoExpiry = nil
        }

        currentTier = best
        entitlementJWS = jws
        await refreshPendingRenewal()
    }

    // MARK: - Codice sviluppatore

    /// Riscatta un codice sul server. Ritorna nil se ok, altrimenti il
    /// messaggio d'errore da mostrare.
    @MainActor
    func redeem(code: String) async -> String? {
        var request = URLRequest(url: BackendConfig.baseURL.appendingPathComponent("v1/redeem"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(BackendConfig.appSecret, forHTTPHeaderField: "x-witp-app")
        request.setValue(BackendConfig.deviceID, forHTTPHeaderField: "x-witp-device")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let jsonObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 200,
                  let token = jsonObj?["token"] as? String,
                  let expiresAt = jsonObj?["expiresAt"] as? Double else {
                switch status {
                case 409: return "Questo codice è già stato usato su un altro dispositivo."
                case 400: return "Codice non valido. Controlla di averlo copiato per intero."
                case 503: return "Il server dei codici non è ancora configurato."
                default:  return "Errore di rete (\(status)). Riprova."
                }
            }
            UserDefaults.standard.set(token, forKey: "witp.promo.token")
            UserDefaults.standard.set(expiresAt / 1000.0, forKey: "witp.promo.expiry")
            await refreshEntitlements()
            return nil
        } catch {
            return "Connessione assente. Riprova quando sei online."
        }
    }

    /// Legge dallo stato StoreKit cosa succederà al rinnovo:
    /// downgrade programmato o disattivazione.
    @MainActor
    private func refreshPendingRenewal() async {
        pendingRenewalTier = nil
        guard currentTier != .free,
              let sub = products.first?.subscription,
              let statuses = try? await sub.status else { return }

        guard let currentID = Self.productID(for: currentTier) else { return }

        for status in statuses {
            guard case .verified(let renewal) = status.renewalInfo,
                  case .verified(let transaction) = status.transaction,
                  transaction.productID == currentID else { continue }

            if !renewal.willAutoRenew {
                pendingRenewalTier = .free
            } else if let next = renewal.autoRenewPreference, next != currentID {
                pendingRenewalTier = Self.tier(forProductID: next)
            }
            return
        }
    }

    // MARK: - Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await MainActor.run { [weak self] in
                    Task { await self?.refreshEntitlements() }
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw NSError(domain: "WITP", code: -1)
        case .verified(let value): return value
        }
    }
}
