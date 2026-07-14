//
//  DesignSystem.swift
//  WITP
//
//  Sistema essenziale. Il vetro è quello NATIVO di iOS 26 (glassEffect):
//  su iOS 27 il materiale si aggiorna da solo. Niente componenti teatrali:
//  quello che non serve alla risposta, non esiste.
//

import SwiftUI

// MARK: - Colori

enum WITPColor {
    static let accent        = Color(red: 0.04, green: 0.52, blue: 1.00)   // blu WITP
    static let accentSoft    = Color(red: 0.04, green: 0.52, blue: 1.00).opacity(0.16)

    static let success       = Color(red: 0.20, green: 0.84, blue: 0.47)
    static let warning       = Color(red: 1.00, green: 0.76, blue: 0.18)
    static let danger        = Color(red: 1.00, green: 0.33, blue: 0.33)

    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary  = Color.secondary.opacity(0.6)

    static let baseTop       = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let baseBottom    = Color(red: 0.02, green: 0.03, blue: 0.05)

    static let card          = Color.white.opacity(0.06)   // sfondo superfici/card
}

// MARK: - Sfondo (per le schermate non-mappa)

struct WITPBackground: View {
    var body: some View {
        LinearGradient(colors: [WITPColor.baseTop, WITPColor.baseBottom],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass nativo

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

struct LiquidGlassPill: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular,
                         in: .capsule)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 26) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius))
    }
    func liquidGlassPill(tint: Color? = nil) -> some View {
        modifier(LiquidGlassPill(tint: tint))
    }
}

// MARK: - Punto colore zona (la legenda vive nei dettagli, non urla in mappa)

struct ZoneDot: View {
    let zone: ParkingZoneType
    var size: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(zone.color)
            .frame(width: size * 1.5, height: size)
            .rotationEffect(.degrees(-14))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                    .rotationEffect(.degrees(-14))
            )
            .accessibilityLabel(zone.label)
    }
}

// MARK: - Font (API usata da SessionsView e SplashView)

enum WITPFont {
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular)
    }
    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - Apple Intelligence · palette e glow

extension WITPColor {
    /// I colori del "pensiero": blu → indaco → viola → rosa → arancio → ciano.
    static let intelligence: [Color] = intelligenceRGB.map {
        Color(red: $0.0, green: $0.1, blue: $0.2)
    }

    private static let intelligenceRGB: [(Double, Double, Double)] = [
        (0.04, 0.52, 1.00),   // blu
        (0.37, 0.36, 0.90),   // indaco
        (0.75, 0.35, 0.95),   // viola
        (1.00, 0.22, 0.37),   // rosa
        (1.00, 0.62, 0.04),   // arancio
        (0.39, 0.82, 1.00),   // ciano
    ]

    /// Colore interpolato lungo la palette (phase ciclica, qualunque valore).
    static func intelligence(at phase: Double) -> Color {
        let p = phase - floor(phase)                       // 0..<1
        let scaled = p * Double(intelligenceRGB.count)
        let i = Int(scaled) % intelligenceRGB.count
        let j = (i + 1) % intelligenceRGB.count
        let f = scaled - floor(scaled)
        let a = intelligenceRGB[i], b = intelligenceRGB[j]
        return Color(red:   a.0 + (b.0 - a.0) * f,
                     green: a.1 + (b.1 - a.1) * f,
                     blue:  a.2 + (b.2 - a.2) * f)
    }
}

/// Il bordo luminoso "sta pensando": l'anello Apple Intelligence che
/// scorre lungo i bordi dello schermo mentre l'app cerca.
struct IntelligenceGlow: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: !active || reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let rot = reduceMotion ? 0.0 : (t.truncatingRemainder(dividingBy: 3.4) / 3.4) * 360.0
            let gradient = AngularGradient(
                colors: WITPColor.intelligence + [WITPColor.intelligence[0]],
                center: .center,
                angle: .degrees(rot)
            )
            ZStack {
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 7)
                    .blur(radius: 9)
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 2)
                    .blur(radius: 1)
                    .opacity(0.85)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.5), value: active)
        .accessibilityHidden(true)
    }
}
