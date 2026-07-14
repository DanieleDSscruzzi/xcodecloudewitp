//
//  OnboardingView.swift
//  WITP
//
//  Un solo schermo. Il prodotto si spiega da sé: una frase, un permesso,
//  dentro. (Il vecchio onboarding a 4 pagine spiegava la pipeline —
//  ma la pipeline non è un problema dell'utente.)
//

import SwiftUI

struct OnboardingView: View {

    let completion: () -> Void

    @EnvironmentObject private var location: LocationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var ringScale: CGFloat = 0.4

    var body: some View {
        ZStack {
            WITPBackground()

            VStack(spacing: 0) {
                Spacer()

                mark
                    .padding(.bottom, 44)

                Text("Trova parcheggio\ndavvero.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                Text("WITP misura gli stalli veri delle tue strade\ne ti dice dove hai più probabilità, adesso.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(WITPColor.textSecondary)
                    .padding(.top, 14)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        HapticManager.medium()
                        location.requestAuthorization()
                        completion()
                    } label: {
                        Text("Consenti posizione e inizia")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(WITPColor.accent)

                    Button("Più tardi") {
                        completion()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WITPColor.textTertiary)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 34)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.15)) {
                appeared = true
            }
            guard !reduceMotion else { ringScale = 1; return }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                ringScale = 1.35
            }
        }
    }

    /// Il marchio: un impulso calmo intorno alla P. Nient'altro.
    private var mark: some View {
        ZStack {
            Circle()
                .stroke(WITPColor.accent.opacity(0.35), lineWidth: 1.5)
                .frame(width: 150, height: 150)
                .scaleEffect(ringScale)
                .opacity(reduceMotion ? 0.5 : Double(1.6 - ringScale))

            Circle()
                .fill(WITPColor.accent.gradient)
                .frame(width: 96, height: 96)
                .shadow(color: WITPColor.accent.opacity(0.5), radius: 24, y: 8)

            Image(systemName: "parkingsign")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
        }
        .scaleEffect(appeared ? 1 : 0.6)
        .opacity(appeared ? 1 : 0)
        .accessibilityHidden(true)
    }
}
