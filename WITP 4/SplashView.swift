//
//  SplashView.swift
//  WITP — l'apertura.
//
//  Un piccolo film procedurale (niente video, solo SwiftUI):
//  notte, una strada, auto in sosta. Un'auto arriva, una luce
//  scende lungo gli stalli come un faro che cerca, trova il posto
//  libero — che si accende con lo shimmer Apple Intelligence e si
//  posa sul bianco — l'auto parcheggia, la scena sfuma e resta
//  il logo. Tap per saltare. Con "Riduci movimento": solo il logo.
//

import SwiftUI
import UIKit

// MARK: - Coordinator (contratto invariato: WITPApp → SplashCoordinator)

struct SplashCoordinator: View {

    @AppStorage("witp.onboarding.done") private var onboardingDone = false

    enum Phase { case intro, onboarding, app }
    @State private var phase: Phase = .intro

    var body: some View {
        ZStack {
            switch phase {
            case .intro:
                CinematicIntro {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        phase = onboardingDone ? .app : .onboarding
                    }
                }
                .transition(.opacity)
            case .onboarding:
                OnboardingView {
                    onboardingDone = true
                    withAnimation(.easeInOut(duration: 0.45)) { phase = .app }
                }
                .transition(.opacity)
            case .app:
                RootView()
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - L'apertura cinematografica

private struct CinematicIntro: View {

    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false

    private let total: Double = 4.7

    var body: some View {
        Group {
            if reduceMotion {
                simpleIntro
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
                    GeometryReader { geo in
                        scene(t: min(tl.date.timeIntervalSince(start), total),
                              size: geo.size)
                    }
                }
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { finish() }
                .task {
                    try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
                    finish()
                }
                .statusBarHidden()
                .accessibilityLabel("Introduzione WITP. Tocca per saltare.")
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }

    // MARK: Scena

    @ViewBuilder
    private func scene(t: Double, size: CGSize) -> some View {
        let w = size.width, h = size.height

        // Layout
        let roadX     = w * 0.36                    // centro corsia
        let roadWidth = w * 0.46
        let stallCX   = w * 0.76                    // centro colonna stalli
        let stallW: CGFloat = 66, stallH: CGFloat = 36
        let stallGap: CGFloat = 46
        let stallYs: [CGFloat] = (0..<5).map { h * 0.46 + CGFloat($0 - 2) * stallGap }
        let targetY = stallYs[2]

        // Tempi
        let driveP  = ease(seg(t, 0.15, 2.15))      // l'auto risale la strada
        let parkP   = ease(seg(t, 2.20, 3.05))      // manovra nello stallo
        let scanP   = ease(seg(t, 0.60, 1.95))      // la luce scandisce gli stalli
        let lockP   = ease(seg(t, 1.95, 2.25))      // …e si blocca sul libero
        let lightIn = ease(seg(t, 0.40, 0.70))
        let glowP   = seg(t, 2.00, 2.50)            // lo stallo si accende (AI)
        let settleP = ease(seg(t, 2.90, 3.40))      // …e si posa sul bianco
        let dimP    = ease(seg(t, 3.30, 3.95))      // buio
        let logoP   = ease(seg(t, 3.45, 4.05))      // logo
        let wordP   = ease(seg(t, 3.65, 4.25))      // wordmark

        ZStack {
            // Asfalto notturno
            LinearGradient(colors: [WITPColor.baseTop, .black],
                           startPoint: .top, endPoint: .bottom)

            // Carreggiata
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.white.opacity(0.04))
                .frame(width: roadWidth, height: h * 1.2)
                .position(x: roadX, y: h / 2)

            // Mezzeria che scorre (rallenta quando l'auto parcheggia)
            laneDashes(t: t, x: roadX, height: h, slow: parkP)

            // Stalli (perpendicolari, aperti verso la strada)
            ForEach(0..<5, id: \.self) { i in
                stall(index: i, t: t,
                      center: CGPoint(x: stallCX, y: stallYs[i]),
                      w: stallW, h: stallH,
                      glowP: glowP, settleP: settleP)
            }

            // Auto già in sosta (statiche, colori spenti)
            parkedCar(color: Color(red: 0.55, green: 0.58, blue: 0.62), at: CGPoint(x: stallCX, y: stallYs[0]))
            parkedCar(color: Color(red: 0.40, green: 0.46, blue: 0.60), at: CGPoint(x: stallCX, y: stallYs[1]))
            parkedCar(color: Color(red: 0.62, green: 0.50, blue: 0.42), at: CGPoint(x: stallCX, y: stallYs[3]))
            parkedCar(color: Color(red: 0.45, green: 0.55, blue: 0.50), at: CGPoint(x: stallCX, y: stallYs[4]))

            // La luce che cerca (il "faro dall'alto")
            scanLight(t: t, lightIn: lightIn, scanP: scanP, lockP: lockP,
                      x: stallCX, ys: stallYs, targetY: targetY, screenH: h)

            // L'auto protagonista
            heroCar(t: t, driveP: driveP, parkP: parkP,
                    roadX: roadX, targetX: stallCX, targetY: targetY, screenH: h)

            // Buio finale + logo
            Color.black.opacity(0.86 * dimP)

            logoBlock(logoP: logoP, wordP: wordP)
                .position(x: w / 2, y: h * 0.46)

            // Hint discreto
            Text("Tocca per saltare")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35 * (1 - dimP)))
                .position(x: w / 2, y: h - 34)
        }
        .ignoresSafeArea()
    }

    // MARK: Elementi

    private func laneDashes(t: Double, x: CGFloat, height: CGFloat, slow: Double) -> some View {
        let spacing: CGFloat = 64
        let speed = 95.0 * (1.0 - 0.75 * slow)
        let offset = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(spacing)))
        return VStack(spacing: spacing - 26) {
            ForEach(0..<14, id: \.self) { _ in
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 5, height: 26)
            }
        }
        .position(x: x, y: height / 2)
        .offset(y: offset - spacing)
    }

    private func stall(index: Int, t: Double, center: CGPoint,
                       w: CGFloat, h: CGFloat,
                       glowP: Double, settleP: Double) -> some View {
        let isTarget = index == 2
        let shimmerOn = isTarget ? glowP * (1 - settleP) : 0

        return ZStack {
            if isTarget && shimmerOn > 0.01 {
                RoundedRectangle(cornerRadius: 5)
                    .fill(WITPColor.intelligence(at: t * 1.5).opacity(0.30 * shimmerOn))
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        AngularGradient(colors: WITPColor.intelligence + [WITPColor.intelligence[0]],
                                        center: .center,
                                        angle: .degrees(t * 240)),
                        lineWidth: 3)
                    .opacity(shimmerOn)
                    .shadow(color: WITPColor.intelligence(at: t).opacity(0.5 * shimmerOn), radius: 10)
            }
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.white.opacity(isTarget ? 0.35 + 0.6 * settleP : 0.5),
                              lineWidth: isTarget ? 2.4 : 1.6)
        }
        .frame(width: w, height: h)
        .position(center)
    }

    private func parkedCar(color: Color, at p: CGPoint) -> some View {
        TopDownCar(color: color, lights: 0, brake: 0)
            .frame(width: 46, height: 24)
            .position(p)
    }

    private func scanLight(t: Double, lightIn: Double, scanP: Double, lockP: Double,
                           x: CGFloat, ys: [CGFloat], targetY: CGFloat, screenH: CGFloat) -> some View {
        let sweepY = lerp(ys[0] - 30, ys[4] + 30, scanP)
        let y = lerp(sweepY, targetY, lockP)
        let pulse = lockP > 0.9 ? 1 + 0.06 * sin(t * 9) : 1.0
        let fade = lightIn * (1 - seg(t, 3.25, 3.7))

        return ZStack {
            // fascio dall'alto
            BeamShape()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.10)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 150, height: y)
                .position(x: x, y: y / 2)

            // alone a terra
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.32), .clear],
                                     center: .center, startRadius: 2, endRadius: 70))
                .frame(width: 140, height: 84)
                .scaleEffect(pulse)
                .position(x: x, y: y)

            // anello intelligence
            Ellipse()
                .strokeBorder(
                    AngularGradient(colors: WITPColor.intelligence + [WITPColor.intelligence[0]],
                                    center: .center, angle: .degrees(t * 180)),
                    lineWidth: 2)
                .frame(width: 120, height: 70)
                .scaleEffect(pulse)
                .position(x: x, y: y)
                .blur(radius: 0.4)
        }
        .opacity(fade)
        .allowsHitTesting(false)
    }

    private func heroCar(t: Double, driveP: Double, parkP: Double,
                         roadX: CGFloat, targetX: CGFloat, targetY: CGFloat,
                         screenH: CGFloat) -> some View {
        let wobble = sin(t * 3.2) * 4 * (1 - parkP)
        let y = lerp(screenH + 80, targetY, driveP)
        let x = lerp(roadX + wobble, targetX, parkP)
        let rotation = Angle.degrees(90 * parkP)   // da "punta in su" a "punta a destra"
        let brake = seg(t, 3.00, 3.12) * (1 - seg(t, 3.45, 3.75))
        let lights = 1 - seg(t, 3.1, 3.5)

        return TopDownCar(color: WITPColor.accent, lights: lights, brake: brake)
            .frame(width: 24, height: 46)
            .rotationEffect(rotation)
            .position(x: x, y: y)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    }

    private func logoBlock(logoP: Double, wordP: Double) -> some View {
        VStack(spacing: 18) {
            Group {
                if let ui = UIImage(named: "witp-mark") {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 30)
                            .fill(WITPColor.accent.gradient)
                        Image(systemName: "parkingsign")
                            .font(.system(size: 58, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: WITPColor.accent.opacity(0.45), radius: 34, y: 10)
            .scaleEffect(0.82 + 0.18 * logoP)
            .opacity(logoP)

            VStack(spacing: 6) {
                Text("WITP")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Where Is The Parking")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                LinearGradient(colors: WITPColor.intelligence,
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 74, height: 3)
                    .clipShape(Capsule())
                    .padding(.top, 6)
            }
            .opacity(wordP)
            .offset(y: (1 - wordP) * 10)
        }
    }

    // MARK: Riduci movimento

    private var simpleIntro: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            logoBlock(logoP: 1, wordP: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            finish()
        }
    }

    // MARK: Easing

    private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(1, max(0, (t - a) / (b - a)))
    }
    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat {
        a + (b - a) * CGFloat(p)
    }
}

// MARK: - Auto vista dall'alto (punta verso l'alto)

private struct TopDownCar: View {
    let color: Color
    let lights: Double     // 0…1 fari accesi
    let brake: Double      // 0…1 stop posteriori

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // carrozzeria
                RoundedRectangle(cornerRadius: w * 0.32, style: .continuous)
                    .fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                         startPoint: .top, endPoint: .bottom))
                // tetto/parabrezza
                RoundedRectangle(cornerRadius: w * 0.2)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: w * 0.66, height: h * 0.34)
                    .position(x: w / 2, y: h * 0.44)
                // fari
                if lights > 0.02 {
                    ForEach([w * 0.28, w * 0.72], id: \.self) { fx in
                        Circle()
                            .fill(Color(red: 1, green: 0.95, blue: 0.75).opacity(0.95 * lights))
                            .frame(width: w * 0.2, height: w * 0.2)
                            .position(x: fx, y: h * 0.08)
                            .shadow(color: .yellow.opacity(0.6 * lights), radius: 5)
                    }
                }
                // stop
                if brake > 0.02 {
                    Capsule()
                        .fill(Color.red.opacity(0.9 * brake))
                        .frame(width: w * 0.64, height: h * 0.07)
                        .position(x: w / 2, y: h * 0.95)
                        .shadow(color: .red.opacity(0.7 * brake), radius: 6)
                }
            }
        }
    }
}

// MARK: - Fascio di luce (trapezio)

private struct BeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - rect.width * 0.14, y: 0))
        p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.14, y: 0))
        p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.46, y: rect.height))
        p.addLine(to: CGPoint(x: rect.midX - rect.width * 0.46, y: rect.height))
        p.closeSubpath()
        return p
    }
}
