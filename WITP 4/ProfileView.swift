//
//  ProfileView.swift
//  WITP
//
//  Il minimo indispensabile: piano, soste, ripristino, contatti.
//  Nessuna chiave da incollare — l'intelligenza vive sul server.
//

import SwiftUI
import StoreKit

struct ProfileView: View {

    @EnvironmentObject private var subs: SubscriptionManager

    @EnvironmentObject private var language: LanguageStore

    @State private var showRedeem = false
    @State private var redeemCode = ""
    @State private var redeemMessage: String?
    @EnvironmentObject private var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var showPaywall = false
    @State private var showManage = false

    var body: some View {
        NavigationStack {
            ZStack {
                WITPBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        planCard

                        redeemRow

                        NavigationLink {
                            SessionsView()
                        } label: {
                            row(icon: "clock.fill", title: "Le mie soste",
                                detail: sessions.sessions.isEmpty ? nil : "\(sessions.sessions.count)")
                        }

                        Button {
                            Task { await subs.restore() }
                        } label: {
                            row(icon: "arrow.clockwise", title: "Ripristina acquisti", detail: nil)
                        }

                        VStack(spacing: 0) {
                            link("Supporto", url: "https://www.whereistheparking.com/support")

                            NavigationLink {
                                LanguagePicker()
                            } label: {
                                settingRow(icon: "globe", title: "Lingua", value: language.displayName)
                            }
                            Divider().padding(.leading, 52)
                            link("Privacy", url: "https://www.whereistheparking.com/support#privacy")
                        }
                        .liquidGlass(cornerRadius: 22)

                        Text("WITP · By D.S. — Verbania\nVersione \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                            .font(.caption2)
                            .foregroundStyle(WITPColor.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 18)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Profilo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .manageSubscriptionsSheet(isPresented: $showManage)
    }

    // MARK: - Piano

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Il tuo piano")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WITPColor.textTertiary)
                    .textCase(.uppercase)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(subs.currentTier.displayName)
                    .font(.title.weight(.bold))
                    .foregroundStyle(subs.currentTier == .free ? .white : WITPColor.accent)
                Spacer()
                Text(subs.currentTier.monthlyPriceLabel + (subs.currentTier == .free ? "" : "/mese"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WITPColor.textSecondary)
            }
            Text(planDetail)
                .font(.footnote)
                .foregroundStyle(WITPColor.textSecondary)

            if let exp = subs.promoExpiry {
                Text("Codice sviluppatore · Ultra+ fino al \(exp.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WITPColor.accent)
            }

            if let pending = subs.pendingRenewalTier {
                Text(pending == .free
                     ? "Si disattiva al prossimo rinnovo"
                     : "Dal prossimo rinnovo: \(pending.displayName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WITPColor.warning)
            }

            Button {
                if subs.currentTier == .free { showPaywall = true } else { showManage = true }
            } label: {
                Text(subs.currentTier == .free ? "Scopri Premium e Turbo" : "Gestisci abbonamento")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(WITPColor.accent)
            .padding(.top, 4)
        }
        .padding(18)
        .liquidGlass(cornerRadius: 26)
    }

    private var planDetail: String {
        let t = subs.currentTier
        if t == .free {
            return "Raggio \(Int(t.searchRadius)) m · fino a \(t.maxStreets) aree"
        }
        return "Risposta entro \(Int(t.answerBudget)) s · raggio \(Int(t.searchRadius)) m · \(t.maxStreets) aree · Claude"
    }

    // MARK: - Codice sviluppatore

    private var redeemRow: some View {
        Button {
            showRedeem = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(WITPColor.accent)
                Text("Ho un codice")
                    .foregroundStyle(WITPColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WITPColor.textSecondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .alert("Codice sviluppatore", isPresented: $showRedeem) {
            TextField("WITP-DEV-…", text: $redeemCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Attiva") {
                let code = redeemCode
                Task {
                    let err = await subs.redeem(code: code)
                    if err == nil { HapticManager.success() }
                    redeemMessage = err ?? "Ultra+ attivo per 2 mesi. Buon lavoro!"
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Ultra+ per 2 mesi, valido una volta per dispositivo.")
        }
        .alert("Codice", isPresented: .init(get: { redeemMessage != nil },
                                            set: { if !$0 { redeemMessage = nil } })) {
            Button("OK") { redeemMessage = nil }
        } message: {
            Text(redeemMessage ?? "")
        }
    }

    @ViewBuilder
    private func settingRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(WITPColor.accent).frame(width: 24)
            Text(title).foregroundStyle(WITPColor.textPrimary)
            Spacer()
            Text(value).font(.footnote).foregroundStyle(WITPColor.textSecondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(WITPColor.textSecondary)
        }
        .padding(16)
        .background(WITPColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Righe

    private func row(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(WITPColor.accent)
                .frame(width: 24)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(WITPColor.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WITPColor.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .liquidGlass(cornerRadius: 22)
    }

    private func link(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.up.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(WITPColor.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
}


// MARK: - Selettore lingua (mondiale)

private struct LanguagePicker: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                row(title: "Automatica (sistema)", tag: "system", subtitle: "Segue la lingua del telefono")
            }
            Section("Lingue") {
                ForEach(AppLanguage.allCases) { lang in
                    row(title: lang.nativeName, tag: lang.rawValue, subtitle: nil)
                }
            }
        }
        .navigationTitle("Lingua")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(title: String, tag: String, subtitle: String?) -> some View {
        Button {
            language.raw = tag
            HapticManager.tap()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(WITPColor.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(WITPColor.textSecondary)
                    }
                }
                Spacer()
                if language.raw == tag { Image(systemName: "checkmark").foregroundStyle(WITPColor.accent) }
            }
        }
    }
}
