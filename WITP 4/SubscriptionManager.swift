//
//  SubscriptionManager.swift
//  WITP
//
//  StoreKit 2 — gestione abbonamenti Free / Premium / Turbo / Ultra / Ultra+.
//

import Foundation
import StoreKit
import Combine

final class SubscriptionManager: ObservableObject {

    /// Istanza condivisa: la usano l'app e gli App Intents (Siri).
    static let shared = SubscriptionManager()


    @Published var currentTier: SubscriptionTier = .free
    /// ID del prodotto realmente sottoscritto (mensile/settimanale/annuale).
    /// Serve per il confronto esatto in refreshPendingRenewal, dato che
    /// un utente può essere abbonato a QUALSIASI periodo, non solo mensile.
    @Published var currentProductID: String?
    /// Ricevuta firmata (JWS) dell'entitlement attivo — inviata al backend
    /// che verifica l'abbonamento e sceglie il modello. Mai nil se abbonato.
    @Published var entitlementJWS: String?
    @Published var products: [Product] = []
    @Published var purchaseInProgress: Bool = false
    @Published var lastError: String?
    /// Cambio piano programmato al prossimo rinnovo (regola App Store:
    /// i downgrade non sono mai immediati). nil = nessun cambio in vista.
    @Published var pendingRenewalTier: SubscriptionTier?

    /// ID reali su App Store Connect. ATTENZIONE: non seguono uno schema
    /// uniforme — mensile ha il punto prima di "Claude2", settimanale e
    /// annuale NON hanno il punto prima del periodo, "weekly" è troncato
    /// a "week", e l'annuale di Ultra ha un "2" extra (ultraannual2) perché
    /// il primo ID scelto era già stato creato/scartato e Apple non
    /// permette di riusare un product ID eliminato. Verificati uno a uno
    /// contro la lista reale in App Store Connect — non rinominare senza
    /// ricontrollare lì, altrimenti StoreKit li scarta in silenzio.
    private let productIDs: Set<String> = [
        // Mensile
        "cobianchi.WITP.premium.Claude2",
        "cobianchi.WITP.turbo.Claude2",
        "cobianchi.WITP.ultra.Claude2",
        "cobianchi.WITP.ultraplus.Claude2",
        // Settimanale
        "cobianchi.WITP.premiumweek.Claude2",
        "cobianchi.WITP.turboweek.Claude2",
        "cobianchi.WITP.ultraweek.Claude2",
        "cobianchi.WITP.ultraplusweek.Claude2",
        // Annuale
        "cobianchi.WITP.premiumannual.Claude2",
        "cobianchi.WITP.turboannual.Claude2",
        "cobianchi.WITP.ultraannual2.Claude2",
        "cobianchi.WITP.ultraplusannual.Claude2"
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

    /// Durata di fatturazione, come sul sito (toggle Weekly/Monthly/Annual).
    enum BillingPeriod: String, CaseIterable, Identifiable {
        case weekly, monthly, annual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weekly:  return "Settimanale"
            case .monthly: return "Mensile"
            case .annual:  return "Annuale"
            }
        }
        var priceSuffix: String {
            switch self {
            case .weekly:  return " /sett."
            case .monthly: return " /mese"
            case .annual:  return " /anno"
            }
        }
    }

    /// Periodo di un product ID. Gli ID reali NON hanno il punto prima del
    /// periodo (es. "premiumweek", non "premium.weekly"), quindi si cerca
    /// la sottostringa, non il suffisso esatto. Nessun nome di tier
    /// contiene "week" o "annual", quindi non ci sono falsi positivi.
    static func period(forProductID id: String) -> BillingPeriod {
        if id.contains("week")   { return .weekly }
        if id.contains("annual") { return .annual }
        return .monthly
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
            // DIAGNOSTICA: quali ID sono stati chiesti ma NON restituiti.
            // In sandbox/TestFlight un ID manca quando su App Store Connect
            // ha metadati incompleti, prezzo non impostato su tutti i
            // territori, sta in un altro gruppo, oppure è scritto diverso
            // anche di un solo carattere.
            let ricevuti = Set(products.map(\.id))
            let mancanti = productIDs.subtracting(ricevuti).sorted()
            if !mancanti.isEmpty {
                print("⛔️ NON restituiti da StoreKit (\(mancanti.count)):")
                for m in mancanti { print("   ✗ \(m)") }
                print("   → confrontali carattere per carattere con App Store Connect")
            } else {
                print("🎉 Tutti i \(productIDs.count) prodotti sono arrivati")
            }
            if products.isEmpty {
                print("⚠️ Nessun prodotto trovato. In sviluppo: Edit Scheme → StoreKit Configuration.")
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
        lastError = nil
        defer { purchaseInProgress = false }
        do {
            print("🛒 Avvio acquisto: \(product.id)")
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
                print("✅ Acquisto completato: \(product.id) → tier \(currentTier)")
            case .userCancelled:
                print("↩️ Acquisto annullato dall'utente")
            case .pending:
                lastError = "Acquisto in sospeso (in attesa di approvazione)."
            @unknown default:
                lastError = "Esito acquisto sconosciuto."
            }
        } catch {
            // Errore VISIBILE: in sviluppo è quasi sempre lo scheme senza
            // StoreKit Configuration, o Sandbox non configurato.
            lastError = "Acquisto non riuscito: \(error.localizedDescription)"
            print("❌ purchase error: \(error)")
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
        var bestProductID: String?
        var jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let t = Self.tier(forProductID: transaction.productID)
            if t.rank > best.rank {
                best = t
                bestProductID = transaction.productID
                jws = result.jwsRepresentation
            }
        }
        // Apple 3.1.1: NESSUN meccanismo diverso da In-App Purchase può
        // sbloccare o elevare un piano. Il tier arriva SOLO dalle
        // Transaction.currentEntitlements sopra.
        currentTier = best
        currentProductID = bestProductID
        entitlementJWS = jws
        await refreshPendingRenewal()
    }

    /// Legge dallo stato StoreKit cosa succederà al rinnovo:
    /// downgrade programmato o disattivazione. Usa currentProductID (l'ID
    /// REALE della transazione attiva) invece di ricostruire un ID mensile
    /// per tier — altrimenti un abbonato settimanale/annuale non avrebbe
    /// mai match e il downgrade programmato non verrebbe mai rilevato.
    @MainActor
    private func refreshPendingRenewal() async {
        pendingRenewalTier = nil
        guard currentTier != .free,
              let currentID = currentProductID,
              let sub = products.first?.subscription,
              let statuses = try? await sub.status else { return }

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
