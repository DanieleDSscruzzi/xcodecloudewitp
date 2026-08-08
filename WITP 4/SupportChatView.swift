//
//  SupportChatView.swift
//  WITP — Assistenza prioritaria "WITP Care".
//
//  Chat con Claude (Sonnet) che conosce tutta l'app: piani, prezzi,
//  funzioni, problemi comuni. Quando l'utente segnala un bug o
//  un'idea, la segnalazione viene archiviata sul server e arriva
//  allo sviluppatore per il prossimo aggiornamento.
//

import SwiftUI

struct SupportChatView: View {

    private struct Msg: Identifiable, Equatable {
        let id = UUID()
        let role: String       // "user" | "assistant"
        let text: String
        var reportSaved: Bool = false
    }

    @State private var messages: [Msg] = []
    @State private var draft: String = ""
    @State private var sending = false
    @State private var errorText: String?

    private var tier: SubscriptionTier { SubscriptionManager.shared.currentTier }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        header
                        ForEach(messages) { m in
                            bubble(m)
                        }
                        if sending {
                            HStack {
                                ProgressView().tint(.white)
                                Text("Claude sta scrivendo…")
                                    .font(.footnote)
                                    .foregroundStyle(WITPColor.textTertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(WITPColor.danger)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: messages) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            inputBar
        }
        .background(WITPBackground())
        .navigationTitle("Assistenza")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Pezzi

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(tier == .free ? "Assistenza WITP" : "Assistenza prioritaria · \(tier.displayName)")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(WITPColor.accent)
            Text("Chiedi qualsiasi cosa su WITP. Se segnali un problema o un'idea, arriva direttamente a By D.S. per il prossimo aggiornamento.")
                .font(.caption)
                .foregroundStyle(WITPColor.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 6)
    }

    private func bubble(_ m: Msg) -> some View {
        VStack(alignment: m.role == "user" ? .trailing : .leading, spacing: 4) {
            Text(m.text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(m.role == "user" ? WITPColor.accent.opacity(0.32)
                                               : Color.white.opacity(0.08))
                )
            if m.reportSaved {
                Label("Segnalazione inviata a By D.S.", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: m.role == "user" ? .trailing : .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Scrivi a WITP Care…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .foregroundStyle(.white)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(WITPColor.accent)
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Rete

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        errorText = nil
        messages.append(Msg(role: "user", text: text))
        sending = true

        Task {
            defer { sending = false }
            var request = URLRequest(url: BackendConfig.baseURL.appendingPathComponent("v1/support"))
            request.httpMethod = "POST"
            request.timeoutInterval = 25
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(BackendConfig.appSecret, forHTTPHeaderField: "x-witp-app")
            request.setValue(BackendConfig.deviceID, forHTTPHeaderField: "x-witp-device")
            let history = messages.suffix(12).map { ["role": $0.role, "content": String($0.text.prefix(600))] }
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "tier": tier.rawValue,
                "messages": history
            ])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if status == 429 {
                    errorText = "Hai raggiunto il limite di messaggi di oggi. Riprova domani, o scrivi a info@whereistheparking.com."
                    return
                }
                guard status == 200, let reply = json?["reply"] as? String, !reply.isEmpty else {
                    errorText = "Assistenza momentaneamente non disponibile. Riprova tra poco."
                    return
                }
                let saved = (json?["reportSaved"] as? Bool) ?? false
                messages.append(Msg(role: "assistant", text: reply, reportSaved: saved))
            } catch {
                errorText = "Connessione assente. Riprova quando sei online."
            }
        }
    }
}
