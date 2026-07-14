//
//  PaywallView.swift
//  WITP
//
//  Il paywall vende una cosa sola, vera: più città e una scelta ragionata.
//  Prezzi e prodotti arrivano da StoreKit (mai hardcoded), l'acquisto
//  è gestito da SubscriptionManager, il modello lo verifica il server.
//

import SwiftUI
import StoreKit

struct PaywallView: View {

    @EnvironmentObject private var subs: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String = "cobianchi.WITP.premium.Claude2"

    var body: some View {
        ZStack {
            WITPBackground()

            ScrollView {
                VStack(spacing: 22) {
                    header
                    radiusRings
                    titleBlock
                    planCards
                    purchaseArea
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
            }
        }
        .onChange(of: subs.currentTier) { _, tier in
            if tier != .free { dismiss() }
        }
        .onChange(of: subs.pendingRenewalTier) { _, pending in
            // Downgrade programmato con successo: conferma e chiudi.
            guard let pending, pending == selectedTier else { return }
            HapticManager.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .accessibilityLabel("Chiudi")
        }
        .padding(.top, 14)
    }

    // MARK: - I tre raggi, in scala reale

    private var radiusRings: some View {
        ZStack {
            ring(fraction: 1.00, color: SubscriptionTier.ultraPlus.accentColor, text: "Ultra+ · 2,5 km")
            ring(fraction: 0.80, color: SubscriptionTier.ultra.accentColor,     text: "Ultra · 2 km")
            ring(fraction: 0.60, color: SubscriptionTier.turbo.accentColor,     text: "Turbo · 1,5 km")
            ring(fraction: 0.40, color: SubscriptionTier.premium.accentColor,   text: "Premium · 1 km")
            ring(fraction: 0.16, color: .gray,                                  text: "Free")
            Circle()
                .fill(WITPColor.accent)
                .frame(width: 10, height: 10)
                .shadow(color: WITPColor.accent, radius: 6)
        }
        .frame(width: 300, height: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Raggi di ricerca: Free 400 metri, Premium 1 chilometro, Turbo 1 e mezzo, Ultra 2, Ultra più 2 e mezzo")
    }

    private func ring(fraction: CGFloat, color: Color, text: String) -> some View {
        ZStack(alignment: .top) {
            Circle()
                .stroke(color.opacity(0.55), style: .init(lineWidth: 1.5, dash: fraction == 1 ? [] : [5, 5]))
            Circle()
                .fill(color.opacity(0.05))
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .offset(y: -9)
        }
        .frame(width: 300 * fraction, height: 300 * fraction)
    }

    // MARK: - Titolo

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Text("Tutta la città.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Dieci, cinque, tre secondi — fino a uno.\nPiù sali, prima parcheggi. A scegliere c'è Claude.")
                .font(.subheadline)
                .foregroundStyle(WITPColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Piani

    private var planCards: some View {
        VStack(spacing: 12) {
            if subs.products.isEmpty {
                Text("Prodotti non disponibili.\nIn sviluppo: Edit Scheme → StoreKit Configuration → Products.storekit")
                    .font(.footnote)
                    .foregroundStyle(WITPColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .liquidGlass(cornerRadius: 22)
            }
            ForEach(subs.products, id: \.id) { product in
                planCard(product)
            }
        }
    }

    private func planCard(_ product: Product) -> some View {
        let tier = SubscriptionManager.tier(forProductID: product.id)
        let selected = product.id == selectedID

        return Button {
            HapticManager.tap()
            selectedID = product.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tier.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(product.displayPrice)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    + Text(" /mese")
                        .font(.footnote)
                        .foregroundStyle(WITPColor.textSecondary)
                }
                Text(features(for: tier))
                    .font(.footnote)
                    .foregroundStyle(WITPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(selected ? tier.accentColor : .white.opacity(0.10),
                            lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .liquidGlass(cornerRadius: 24)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func features(for tier: SubscriptionTier) -> String {
        switch tier {
        case .premium:   return "Risposta entro 10 secondi · raggio 1 km · 15 aree · Claude Haiku"
        case .turbo:     return "Risposta entro 5 secondi · raggio 1,5 km · 30 aree · Claude Sonnet · priorità"
        case .ultra:     return "Risposta entro 3 secondi · prefetch continuo · raggio 2 km · 40 aree · Claude Opus"
        case .ultraPlus: return "Risposta entro 1 secondo · ragiona sul chip (Neural Engine) · Claude Fable 5 · raggio 2,5 km · 50 aree"
        case .free:      return ""
        }
    }

    // MARK: - Acquisto

    private var purchaseArea: some View {
        VStack(spacing: 12) {
            Button {
                guard let product = subs.products.first(where: { $0.id == selectedID }) else { return }
                HapticManager.medium()
                Task { await subs.purchase(product) }
            } label: {
                Group {
                    if subs.purchaseInProgress {
                        ProgressView().tint(.white)
                    } else {
                        Text(ctaLabel)
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(WITPColor.accent)
            .disabled(subs.purchaseInProgress || subs.products.isEmpty || selectedTier == subs.currentTier)

            if let pending = subs.pendingRenewalTier {
                Text(pending == .free
                     ? "L'abbonamento si disattiverà al prossimo rinnovo."
                     : "Cambio programmato: dal prossimo rinnovo passerai a \(pending.displayName).")
                    .font(.caption)
                    .foregroundStyle(WITPColor.warning)
                    .multilineTextAlignment(.center)
            }

            if let err = subs.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(WITPColor.danger)
                    .multilineTextAlignment(.center)
            }

            Button("Ripristina acquisti") {
                Task { await subs.restore() }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WITPColor.textSecondary)
        }
    }

    private var selectedTier: SubscriptionTier {
        SubscriptionManager.tier(forProductID: selectedID)
    }

    private var isDowngrade: Bool {
        selectedTier.rank < subs.currentTier.rank
    }

    private var ctaLabel: String {
        guard let p = subs.products.first(where: { $0.id == selectedID }) else { return "Attiva" }
        if selectedTier == subs.currentTier { return "Piano attivo" }
        if isDowngrade { return "Passa a \(selectedTier.displayName) al rinnovo — \(p.displayPrice)/mese" }
        return "Attiva \(selectedTier.displayName) — \(p.displayPrice)/mese"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Abbonamento mensile gestito dall'App Store.\nSi rinnova da solo, lo disdici quando vuoi dalle Impostazioni.")
                .font(.caption2)
                .foregroundStyle(WITPColor.textTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Termini d'uso",
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy",
                     destination: URL(string: "https://whereistheparking.com/support.html")!)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(WITPColor.textSecondary)
        }
        .padding(.top, 4)
    }
}
