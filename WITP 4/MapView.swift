//
//  MapView.swift
//  WITP — la Home. L'unica schermata.
//
//  Una mappa. Un tasto. Una risposta.
//  Tutto il lavoro (3 fonti, geometria, modello, Claude) succede sotto:
//  l'utente vede solo parole umane e IL parcheggio dove andare.
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

struct WITPMapView: View {

    @EnvironmentObject private var engine: ParkingEngine
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var subs: SubscriptionManager
    @EnvironmentObject private var sessions: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Mappa
    @State private var camera: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: .init(latitude: 45.9236, longitude: 8.5512),
            span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012))))
    @State private var cameraCenter: CLLocationCoordinate2D?
    @State private var cameraDistance: Double = 2000

    // Interazione
    @State private var selectedSpot: ParkingSpot?
    @State private var showProfile = false
    @State private var showPaywall = false
    @State private var showAlternatives = false
    @State private var showSessions = false
    @State private var autoSearchWhenLocated = false

    // Prefetch (piani Ultra): i dati sono già caldi prima del tocco.
    @State private var lastPrefetch: (loc: CLLocationCoordinate2D, at: Date)?

    // Comandi arrivati da Siri mentre l'app era chiusa
    @State private var siriNavigatePending = false

    // Reveal Apple Intelligence degli stalli
    @State private var revealAt: Date?
    @State private var cameraStamp: Int = 0

    // Impulso di ricerca sulla mappa (animato solo mentre si cerca)
    @State private var pulse: Double = 0

    // Feedback "l'hai trovato libero?"
    @State private var pendingFeedback: (spot: ParkingSpot, at: Date)?
    @State private var showFeedback = false

    // MARK: - Body

    var body: some View {
        ZStack {
            map
            if engine.isSearching {
                IntelligenceGlow(active: true)
                    .transition(.opacity)
            }
            overlay
        }
        .animation(.easeInOut(duration: 0.45), value: engine.isSearching)
        .sheet(isPresented: $showProfile)  { ProfileView() }
        .sheet(isPresented: $showPaywall)  { PaywallView() }
        .sheet(isPresented: $showSessions) { NavigationStack { SessionsView() } }
        .sheet(isPresented: $showAlternatives) { alternativesSheet }
        .task(id: engine.isSearching) {
            // Il battito vive solo durante la ricerca: zero lavoro da fermi.
            guard engine.isSearching, !reduceMotion else { pulse = 0; return }
            while !Task.isCancelled && engine.isSearching {
                pulse += 1.0 / 50.0
                if pulse >= 1 { pulse = 0 }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            pulse = 0
        }
        .onChange(of: engine.phase) { _, phase in
            if phase == .done { onSearchDone() }
        }
        .onChange(of: location.currentLocation != nil) { _, has in
            if has && autoSearchWhenLocated {
                autoSearchWhenLocated = false
                search(at: location.currentLocation!)
            }
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active {
                maybeAskFeedback()
                consumeSiriFlags()
            }
        }
        .onAppear { consumeSiriFlags() }
        .onChange(of: location.currentLocation?.latitude) { _, _ in maybePrefetch() }
        .task(id: subs.currentTier) { maybePrefetch() }
    }

    // MARK: - Mappa

    private var map: some View {
        MapReader { proxy in
            mapContent(proxy)
        }
    }

    private func mapContent(_ proxy: MapProxy) -> some View {
        Map(position: $camera, interactionModes: .all) {
            UserAnnotation()

            // Impulso di ricerca: un solo gesto fisico, sobrio.
            if engine.isSearching, let c = engine.scanCenter {
                MapCircle(center: c, radius: engine.scanRadius)
                    .stroke(WITPColor.accent.opacity(0.28), lineWidth: 1)
                if !reduceMotion {
                    MapCircle(center: c, radius: max(4, engine.scanRadius * pulse))
                        .stroke(WITPColor.accent.opacity(0.8 * (1 - pulse)), lineWidth: 2.5)
                }
            }

            // Ogni parcheggio DEVE comparire. Chi ha la geometria vera la
            // mostra col Canvas (vernice); chi NON ce l'ha — multipiano, POI
            // Apple, nodi — appare come pallino colorato. Nessuno sparisce.
            ForEach(engine.spots.filter { $0.id != answer?.id }) { spot in
                Annotation("", coordinate: spot.coordinate) {
                    if spot.stripes.isEmpty {
                        SpotDot(zone: spot.zoneType, count: spot.stallCount)
                            .onTapGesture { select(spot) }
                            .accessibilityLabel("\(spot.streetName), \(Int(spot.availability * 100)) per cento")
                            .accessibilityAddTraits(.isButton)
                    } else {
                        // Ha gli stalli dipinti: solo area di tocco invisibile.
                        Circle()
                            .fill(Color.white.opacity(0.001))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .onTapGesture { select(spot) }
                            .accessibilityLabel("\(spot.streetName), \(Int(spot.availability * 100)) per cento")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .annotationTitles(.hidden)
            }

            // LA risposta.
            if let best = answer {
                Annotation("", coordinate: best.coordinate) {
                    BestPin(level: best.availabilityLevel,
                            intelligent: engine.insight != nil)
                        .onTapGesture { select(best) }
                        .accessibilityLabel("Parcheggio consigliato: \(best.streetName)")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { ctx in
            cameraCenter = ctx.camera.centerCoordinate
            cameraDistance = ctx.camera.distance
            if !engine.spots.isEmpty && ctx.camera.distance < 3200 {
                cameraStamp &+= 1   // ridisegna il Canvas solo se ci sono stalli in vista
            }
        }
        .overlay {
            // Gli stalli veri, dipinti sopra la mappa: nascono con lo
            // shimmer Apple Intelligence e si posano sul colore di zona.
            StallCanvas(proxy: proxy,
                        spots: engine.spots,
                        revealAt: revealAt,
                        settled: engine.phase == .done,
                        cameraDistance: cameraDistance,
                        cameraStamp: cameraStamp,
                        reduceMotion: reduceMotion)
        }
        .ignoresSafeArea()
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if showFeedback, let pf = pendingFeedback {
                feedbackToast(pf.spot)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 10)
            }
            bottomArea
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86),
                   value: engine.phase)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86),
                   value: selectedSpot?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86),
                   value: engine.insight?.bestSpotID)
        .animation(.default, value: showFeedback)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if let active = sessions.active {
                Button { showSessions = true } label: {
                    SessionChip(session: active)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sosta in corso")
            }
            Spacer()
            Button { showProfile = true } label: {
                Image(systemName: "person.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .accessibilityLabel("Profilo")
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var bottomArea: some View {
        if engine.isSearching {
            SearchingPill(text: phaseText, thinking: engine.phase == .choosing)
        } else if engine.phase == .done, engine.spots.isEmpty {
            EmptyCard(tier: subs.currentTier,
                      retry: { startSearch() },
                      upgrade: { showPaywall = true })
        } else if let best = answer {
            AnswerCard(
                spot: best,
                summary: summaryLine(for: best),
                isFree: subs.currentTier == .free,
                alternativesCount: max(0, engine.spots.count - 1),
                onGo: { go(to: best) },
                onPark: { startSession(best) },
                onAlternatives: { showAlternatives = true },
                onUpgrade: { showPaywall = true },
                onClose: { close() }
            )
        } else {
            findButton
        }
    }

    private var findButton: some View {
        VStack(spacing: 10) {
            if shouldOfferSearchHere {
                Button { if let c = cameraCenter { search(at: c) } } label: {
                    Label("Cerca in quest'area", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(.glass)
                .transition(.opacity)
            }
            Button(action: startSearch) {
                Label("Trova parcheggio", systemImage: "parkingsign")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(WITPColor.accent)
            .accessibilityHint("Cerca i parcheggi liberi intorno a te")
        }
    }

    // MARK: - Logica

    /// La risposta mostrata: la selezione dell'utente, altrimenti la scelta dell'engine.
    private var answer: ParkingSpot? {
        guard engine.phase == .done else { return nil }
        return selectedSpot ?? engine.bestSpot
    }

    private var phaseText: String {
        switch engine.phase {
        case .looking:   return "Guardo le strade qui intorno…"
        case .measuring: return "Misuro gli stalli…"
        case .scoring:   return "Calcolo le probabilità…"
        case .choosing:  return "Scelgo il migliore…"
        case .widening:  return "Allargo la ricerca…"
        default:         return "Un attimo…"
        }
    }

    /// La riga che spiega la risposta. Claude se c'è, il modello locale altrimenti.
    private func summaryLine(for spot: ParkingSpot) -> String {
        if let insight = engine.insight,
           insight.bestSpotID == spot.id || (insight.bestSpotID == nil && spot.id == engine.bestSpot?.id) {
            return insight.summary
        }
        return spot.availabilityReasoning.first ?? spot.zoneType.label
    }

    private var shouldOfferSearchHere: Bool {
        guard let c = cameraCenter else { return false }
        if let scanned = engine.scanCenter {
            return distance(c, scanned) > 220
        }
        if let user = location.currentLocation {
            return distance(c, user) > 220
        }
        return false
    }

    /// Comandi Siri lasciati in coda ("portami al parcheggio/alla macchina").
    private func consumeSiriFlags() {
        let d = UserDefaults.standard
        if d.bool(forKey: "witp.siri.navigate") {
            d.set(false, forKey: "witp.siri.navigate")
            if let best = engine.bestSpot, engine.phase == .done {
                go(to: best)
            } else {
                siriNavigatePending = true
                startSearch()
            }
        }
        if d.bool(forKey: "witp.siri.car") {
            d.set(false, forKey: "witp.siri.car")
            navigateToCar()
        }
    }

    private func navigateToCar() {
        guard let s = sessions.sessions.first else { return }
        let item = MKMapItem(
            location: CLLocation(latitude: s.coordinate.latitude,
                                 longitude: s.coordinate.longitude),
            address: nil
        )
        item.name = s.notes.isEmpty ? "La tua auto" : s.notes
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    /// Ultra/Ultra+: riscalda la cache intorno all'utente mentre non fa nulla.
    private func maybePrefetch() {
        guard subs.currentTier.prefetches,
              let loc = location.currentLocation else { return }
        if let last = lastPrefetch,
           distance(loc, last.loc) < 300,
           Date().timeIntervalSince(last.at) < 600 { return }
        lastPrefetch = (loc, Date())
        let radius = subs.currentTier.searchRadius
        Task.detached(priority: .utility) {
            await StreetFinder.shared.prefetch(near: loc, radius: radius)
        }
    }

    private func startSearch() {
        HapticManager.medium()
        if let loc = location.currentLocation {
            search(at: loc)
        } else {
            autoSearchWhenLocated = true
            location.requestAuthorization()
        }
    }

    private func search(at center: CLLocationCoordinate2D) {
        selectedSpot = nil
        revealAt = nil
        withAnimation { camera = .region(region(around: center, radius: subs.currentTier.searchRadius)) }
        engine.run(center: center, tier: subs.currentTier, jws: subs.entitlementJWS)
    }

    private func onSearchDone() {
        revealAt = Date()
        guard let best = engine.bestSpot else {
            HapticManager.warning()
            siriNavigatePending = false
            return
        }
        HapticManager.success()
        if siriNavigatePending {
            siriNavigatePending = false
            go(to: best)
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
            camera = .region(region(around: best.coordinate, radius: 260))
        }
    }

    private func select(_ spot: ParkingSpot) {
        HapticManager.tap()
        selectedSpot = spot
        withAnimation { camera = .region(region(around: spot.coordinate, radius: 240)) }
    }

    private func close() {
        HapticManager.tap()
        selectedSpot = nil
        revealAt = nil
        engine.reset()
    }

    private func go(to spot: ParkingSpot) {
        HapticManager.medium()
        let item = MKMapItem(
            location: CLLocation(latitude: spot.coordinate.latitude,
                                 longitude: spot.coordinate.longitude),
            address: nil
        )
        item.name = spot.streetName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        pendingFeedback = (spot, Date())
    }

    private func startSession(_ spot: ParkingSpot) {
        HapticManager.success()
        sessions.startSession(coordinate: spot.coordinate,
                              zoneType: spot.zoneType,
                              durationMinutes: nil,
                              notes: spot.streetName)
        showSessions = true
    }

    // MARK: - Feedback loop (nutre il modello locale)

    private func maybeAskFeedback() {
        guard let pf = pendingFeedback,
              Date().timeIntervalSince(pf.at) > 120,
              !showFeedback else { return }
        showFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            showFeedback = false
        }
    }

    private func feedbackToast(_ spot: ParkingSpot) -> some View {
        HStack(spacing: 14) {
            Text("L'hai trovato libero?")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Button {
                AvailabilityPredictor.shared.recordFeedback(for: spot, foundFree: true)
                HapticManager.success()
                dismissFeedback()
            } label: {
                Image(systemName: "hand.thumbsup.fill").frame(width: 40, height: 34)
            }
            .buttonStyle(.glass)
            Button {
                AvailabilityPredictor.shared.recordFeedback(for: spot, foundFree: false)
                HapticManager.tap()
                dismissFeedback()
            } label: {
                Image(systemName: "hand.thumbsdown").frame(width: 40, height: 34)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .liquidGlass(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hai trovato il parcheggio libero? Rispondi per migliorare le previsioni.")
    }

    private func dismissFeedback() {
        showFeedback = false
        pendingFeedback = nil
    }

    // MARK: - Alternative

    private var alternativesSheet: some View {
        NavigationStack {
            List(engine.spots) { spot in
                Button {
                    showAlternatives = false
                    select(spot)
                } label: {
                    HStack(spacing: 12) {
                        ZoneDot(zone: spot.zoneType)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.streetName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(Int(spot.distanceFromUser)) m · ≈\(spot.stallCount) stalli · \(spot.zoneType.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(spot.availability * 100))%")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(spot.availabilityLevel.color)
                        if spot.id == answer?.id {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WITPColor.accent)
                        }
                    }
                }
            }
            .navigationTitle("Vicino a te")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { showAlternatives = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    private func region(around c: CLLocationCoordinate2D, radius: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: c,
                           latitudinalMeters: radius * 2.6,
                           longitudinalMeters: radius * 2.6)
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

// MARK: - Il pin della risposta

private struct BestPin: View {
    let level: AvailabilityLevel
    var intelligent: Bool = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            if intelligent {
                Circle()
                    .strokeBorder(AngularGradient(colors: WITPColor.intelligence + [WITPColor.intelligence[0]],
                                                  center: .center),
                                  lineWidth: 2.5)
                    .frame(width: 54, height: 54)
                    .blur(radius: 0.4)
            }
            Circle()
                .fill(WITPColor.accent.gradient)
                .frame(width: 44, height: 44)
                .shadow(color: WITPColor.accent.opacity(0.45), radius: 10, y: 4)
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 2)
                .frame(width: 44, height: 44)
            Image(systemName: "parkingsign")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(level.color)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .offset(x: 3, y: -3)
        }
        .scaleEffect(appeared ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

// MARK: - Ricerca in corso: una pillola, parole umane

private struct SearchingPill: View {
    let text: String
    var thinking: Bool = false
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(thinking
                    ? AnyShapeStyle(LinearGradient(colors: WITPColor.intelligence,
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(.primary))
                .contentTransition(.opacity)
                .id(text)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 30)
        .accessibilityLabel("Ricerca in corso. \(text)")
    }
}

// MARK: - La risposta

private struct AnswerCard: View {
    let spot: ParkingSpot
    let summary: String
    let isFree: Bool
    let alternativesCount: Int
    let onGo: () -> Void
    let onPark: () -> Void
    let onAlternatives: () -> Void
    let onUpgrade: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZoneDot(zone: spot.zoneType)
                    .padding(.top, 2)
                Text(spot.streetName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .clipShape(Circle())
                .accessibilityLabel("Chiudi risultato")
            }

            HStack(spacing: 6) {
                Text("\(Int(spot.availability * 100))%")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(spot.availabilityLevel.color)
                Text("adesso · \(Int(spot.distanceFromUser)) m · ≈\(spot.stallCount) stalli · \(spot.zoneType.label)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onGo) {
                Label("Portami lì", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(WITPColor.accent)

            HStack {
                Button("Avvia sosta", action: onPark)
                Spacer()
                if alternativesCount > 0 {
                    Button("Alternative (\(alternativesCount))", action: onAlternatives)
                }
            }
            .font(.subheadline.weight(.medium))
            .tint(WITPColor.accent)

            if isFree {
                Button(action: onUpgrade) {
                    Text("Con Premium cerco fino a 1 km e scelgo io il migliore →")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .liquidGlass(cornerRadius: 30)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Nessun risultato

private struct EmptyCard: View {
    let tier: SubscriptionTier
    let retry: () -> Void
    let upgrade: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "parkingsign.slash")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Nessun parcheggio mappato qui vicino")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Ho allargato la ricerca e provato perfino a stimare il bordo strada: qui non risulta mappato nulla. Prova a spostarti.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Riprova", action: retry)
                    .buttonStyle(.glass)
                if tier == .free {
                    Button("Passa a Premium", action: upgrade)
                        .buttonStyle(.glassProminent)
                        .tint(WITPColor.accent)
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 30)
    }
}

// MARK: - Sosta attiva (capsula quieta in alto)

private struct SessionChip: View {
    let session: ParkingSession
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "car.fill")
                .font(.footnote.weight(.semibold))
            if let end = session.endDate {
                Text(format(max(0, end.timeIntervalSince(now))))
                    .font(.footnote.weight(.semibold).monospacedDigit())
            } else {
                Text("Sosta attiva")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liquidGlassPill(tint: WITPColor.accent)
        .onReceive(timer) { now = $0 }
    }

    private func format(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, sec)
                       : String(format: "%02d:%02d", m, sec)
    }
}


// MARK: - Gli stalli, dipinti: reveal Apple Intelligence → colore di zona

private struct StallCanvas: View {
    let proxy: MapProxy
    let spots: [ParkingSpot]
    let revealAt: Date?
    let settled: Bool
    let cameraDistance: Double
    let cameraStamp: Int
    let reduceMotion: Bool

    private var animating: Bool {
        guard !reduceMotion, let r = revealAt else { return false }
        return Date().timeIntervalSince(r) < 6.5
    }

    var body: some View {
        // cameraStamp è nella firma: ogni pan/zoom rigenera la view → il
        // Canvas si ridisegna anche quando la timeline è in pausa.
        let _ = cameraStamp
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: !animating)) { tl in
            Canvas(rendersAsynchronously: true) { ctx, size in
                draw(in: &ctx, size: size, now: tl.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Disegno

    private func draw(in ctx: inout GraphicsContext, size: CGSize, now: Date) {
        guard settled || revealAt != nil else { return }
        guard cameraDistance < 3000 else { return }

        // Dissolvenza legata allo zoom (3000 → 2500 m di distanza camera)
        let zoomAlpha = min(1, max(0, (3000 - cameraDistance) / 500))
        guard zoomAlpha > 0.02 else { return }

        // LOD: da lontano campiona gli stalli (uno sì e uno no) — a quelle
        // distanze sono chiazze di colore, il dettaglio non serve.
        let stride = cameraDistance > 1500 ? 2 : 1

        let screen = CGRect(origin: .zero, size: size).insetBy(dx: -50, dy: -50)
        let elapsed = revealAt.map { now.timeIntervalSince($0) } ?? 999
        let instant = reduceMotion || revealAt == nil

        // Budget EQUO: ogni parcheggio visibile riceve la sua quota di stalli.
        // Prima il budget era globale e in Turbo (30 aree) si esauriva sui
        // primi parcheggi lasciando gli altri nudi.
        var visible: [(Int, ParkingSpot)] = []
        for (si, spot) in spots.enumerated() {
            if let p = proxy.convert(spot.coordinate, to: .local),
               screen.insetBy(dx: -260, dy: -260).contains(p) {
                visible.append((si, spot))
            }
        }
        guard !visible.isEmpty else { return }
        let perSpot = max(36, 1600 / visible.count)

        for (si, spot) in visible {
            var drawn = 0
            let step = max(stride, Int((Double(spot.stripes.count) / Double(perSpot)).rounded(.up)))
            let spotDelay = 0.35 + Double(si) * 0.12

            for (k, stripe) in spot.stripes.enumerated() {
                guard drawn < perSpot else { break }
                if step > 1 && k % step != 0 { continue }

                // Fase temporale di QUESTO stallo (onda che attraversa il lotto)
                let d = spotDelay + min(1.0, Double(k) * 0.010)
                let a = instant ? 999 : elapsed - d
                if a < 0 { continue }

                // Proiezione a schermo
                var pts: [CGPoint] = []
                pts.reserveCapacity(4)
                var anyInside = false
                for c in stripe.polygon {
                    guard let p = proxy.convert(c, to: .local) else { pts = []; break }
                    pts.append(p)
                    if screen.contains(p) { anyInside = true }
                }
                guard pts.count == 4, anyInside else { continue }
                drawn += 1

                var path = Path()
                path.move(to: pts[0])
                path.addLine(to: pts[1])
                path.addLine(to: pts[2])
                path.addLine(to: pts[3])
                path.closeSubpath()

                let appear = min(1, a / 0.22)
                let shimmerEnd = 1.05, blendEnd = 1.5

                if a < blendEnd {
                    // — Shimmer Apple Intelligence: acceso, poi si spegne nel colore vero
                    let phase = a * 1.7 + Double(k) * 0.055 + Double(si) * 0.31
                    let fade = a < shimmerEnd ? 1.0 : 1.0 - (a - shimmerEnd) / (blendEnd - shimmerEnd)
                    let sAlpha = 0.92 * fade * appear * zoomAlpha
                    let c1 = WITPColor.intelligence(at: phase).opacity(sAlpha)
                    let c2 = WITPColor.intelligence(at: phase + 0.22).opacity(sAlpha)
                    ctx.fill(path, with: .linearGradient(
                        Gradient(colors: [c1, c2]),
                        startPoint: pts[0], endPoint: pts[2]))
                    ctx.stroke(path, with: .color(.white.opacity(0.75 * sAlpha)),
                               lineWidth: 1.1)
                }

                if a >= shimmerEnd {
                    // — Colore di zona (in crossfade, poi stabile)
                    let kk = min(1, (a - shimmerEnd) / (blendEnd - shimmerEnd))
                    paintZone(stripe: stripe, path: path, pts: pts,
                              alpha: kk * appear * zoomAlpha, in: &ctx)
                }
            }
        }
    }

    /// La "vernice" definitiva: bianco a righe, blu, giallo, rosso + ♿.
    private func paintZone(stripe: ParkingStripe, path: Path, pts: [CGPoint],
                           alpha: Double, in ctx: inout GraphicsContext) {
        guard alpha > 0.02 else { return }
        let z = stripe.zoneType

        let fillOpacity: Double
        let strokeColor: Color
        switch z {
        case .free:     fillOpacity = 0.13; strokeColor = .white
        case .paid:     fillOpacity = 0.40; strokeColor = z.color
        case .reserved: fillOpacity = 0.38; strokeColor = z.color
        case .disabled: fillOpacity = 0.42; strokeColor = .white
        }

        ctx.fill(path, with: .color(z.color.opacity(fillOpacity * alpha)))
        let side = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
        if side > 3.5 {
            ctx.stroke(path, with: .color(strokeColor.opacity(0.92 * alpha)), lineWidth: 1.3)
        }

        // ♿ dentro gli stalli disabili, orientato con lo stallo
        if z == .disabled {
            let e1 = CGVector(dx: pts[1].x - pts[0].x, dy: pts[1].y - pts[0].y)
            let e2 = CGVector(dx: pts[3].x - pts[0].x, dy: pts[3].y - pts[0].y)
            let l1 = hypot(e1.dx, e1.dy), l2 = hypot(e2.dx, e2.dy)
            let short = min(l1, l2)
            guard short >= 11 else { return }
            let long = l1 >= l2 ? e1 : e2
            let angle = atan2(long.dy, long.dx) - .pi / 2
            let cx = (pts[0].x + pts[2].x) / 2
            let cy = (pts[0].y + pts[2].y) / 2

            ctx.drawLayer { layer in
                layer.translateBy(x: cx, y: cy)
                layer.rotate(by: Angle(radians: angle))
                let glyph = Text(Image(systemName: "figure.roll"))
                    .font(.system(size: short * 0.62, weight: .bold))
                    .foregroundStyle(Color.white.opacity(alpha))
                layer.draw(layer.resolve(glyph), at: .zero, anchor: .center)
            }
        }
    }
}


// MARK: - Pallino per i parcheggi senza geometria (multipiano/POI/nodi)

private struct SpotDot: View {
    let zone: ParkingZoneType
    let count: Int
    @State private var appeared = false

    var body: some View {
        // Pillola col simbolo della zona + capienza: un parcheggio senza
        // geometria (multipiano, POI) resta leggibile e non sembra un bug.
        HStack(spacing: 4) {
            Image(systemName: zone == .disabled ? "figure.roll" : "p.square.fill")
                .font(.system(size: 11, weight: .bold))
            if count > 0 {
                Text("~\(count)")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(zone.color))
        .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        .scaleEffect(appeared ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: appeared)
        .onAppear { appeared = true }
        .contentShape(Capsule().inset(by: -12))
    }
}
