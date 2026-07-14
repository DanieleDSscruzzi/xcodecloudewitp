//
//  SessionsView.swift
//  WITP
//

import SwiftUI
import MapKit
import Combine

struct SessionsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            WITPBackground()
            if store.sessions.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let active = store.active { activeCard(active).padding(.top, 12) }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Storico")
                                .font(WITPFont.title(13))
                                .foregroundStyle(.white)
                                .padding(.top, 6)

                            ForEach(store.sessions.filter { !$0.isActive }) { s in
                                row(s)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 100)
                }
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(WITPColor.textTertiary)
            Text("Nessuna sessione")
                .font(WITPFont.title(16))
                .foregroundStyle(.white)
            Text("Le tue soste appariranno qui")
                .font(WITPFont.body(12))
                .foregroundStyle(WITPColor.textSecondary)
        }
        .padding(30)
    }

    private func activeCard(_ s: ParkingSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Sessione attiva", systemImage: "record.circle.fill")
                    .font(WITPFont.label(10))
                    .foregroundStyle(WITPColor.success)
                    .symbolEffect(.pulse, options: .repeating)
                Spacer()
                Text(s.zoneType.label)
                    .font(WITPFont.label(9))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(s.zoneType.color.opacity(0.3)))
            }

            VStack(spacing: 2) {
                if let rem = s.remainingSeconds {
                    Text(formatTime(rem))
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(rem < 600 ? WITPColor.warning : .white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("rimanenti")
                        .font(WITPFont.label(9))
                        .foregroundStyle(WITPColor.textTertiary)
                } else {
                    Text(formatElapsed(since: s.startedAt))
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("trascorsi")
                        .font(WITPFont.label(9))
                        .foregroundStyle(WITPColor.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            Map(position: .constant(.region(MKCoordinateRegion(
                center: s.coordinate.clLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003))))) {
                Marker("Auto", systemImage: "car.fill",
                       coordinate: s.coordinate.clLocation)
                    .tint(s.zoneType.color)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .allowsHitTesting(false)

            VStack(spacing: 8) {
                Button {
                    let placemark = MKPlacemark(coordinate: s.coordinate.clLocation)
                    MKMapItem(placemark: placemark).openInMaps(launchOptions: [
                        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
                    ])
                } label: {
                    Label("Torna all'auto", systemImage: "figure.walk")
                        .font(WITPFont.title(12))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .liquidGlass(cornerRadius: 11)
                }
                .buttonStyle(.plain)

                Button {
                    HapticManager.warning()
                    store.endActiveSession()
                } label: {
                    Label("Termina sessione", systemImage: "stop.fill")
                        .font(WITPFont.title(12))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(WITPColor.danger.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 16)
    }

    private func row(_ s: ParkingSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.zoneType.symbol)
                .font(.system(size: 14))
                .foregroundStyle(s.zoneType.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(s.zoneType.color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.zoneType.label).font(WITPFont.title(12)).foregroundStyle(.white)
                Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(WITPFont.label(9)).foregroundStyle(WITPColor.textSecondary)
            }
            Spacer()
            if let d = s.durationMinutes {
                Text("\(d)'").font(WITPFont.mono(11)).foregroundStyle(WITPColor.textTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.04)))
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
    private func formatElapsed(since d: Date) -> String { formatTime(now.timeIntervalSince(d)) }
}
