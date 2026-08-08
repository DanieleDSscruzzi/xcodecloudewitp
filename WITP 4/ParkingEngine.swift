//
//  ParkingEngine.swift
//  WITP
//
//  La pipeline resta identica (3 fonti reali → geometria → modello locale
//  → Claude sui piani a pagamento). Cambia la superficie: la UI vede una
//  sola storia — sto cercando / ho una risposta — senza gergo tecnico.
//

import Foundation
import CoreLocation
import os.log
import Combine

// MARK: - Fase (parole umane, decise dalla UI)

enum SearchPhase: Equatable {
    case idle
    case looking      // interrogo le fonti
    case measuring    // geometria stalli
    case scoring      // modello locale
    case choosing     // Claude sceglie (solo Premium/Turbo)
    case widening     // zero risultati: allargo — un parcheggio SI TROVA
    case done
}

// MARK: - Engine

@MainActor
final class ParkingEngine: ObservableObject {

    /// Istanza condivisa: la usano l'app e gli App Intents (Siri).
    static let shared = ParkingEngine()


    @Published var phase: SearchPhase = .idle
    @Published var spots: [ParkingSpot] = []
    @Published var insight: ClaudeInsight?
    @Published var errorMessage: String?
    @Published var lastResult: ParkingScanResult?

    @Published var scanCenter: CLLocationCoordinate2D?
    @Published var scanRadius: Double = 0

    var isSearching: Bool { phase != .idle && phase != .done }

    /// La risposta: lo spot scelto da Claude, altrimenti il primo per punteggio.
    var bestSpot: ParkingSpot? {
        if let id = insight?.bestSpotID, let s = spots.first(where: { $0.id == id }) { return s }
        return spots.first
    }

    private let logger = Logger(subsystem: "com.danielescruzzi.witp", category: "ParkingEngine")
    private var currentTask: Task<Void, Never>?
    private var scanID = UUID()   // guardia: i risultati tardivi valgono solo per la scansione corrente

    func run(center: CLLocationCoordinate2D, tier: SubscriptionTier, jws: String?) {
        cancel()
        scanID = UUID()
        currentTask = Task(priority: .userInitiated) { [weak self] in
            await self?.runInternal(center: center, tier: tier, jws: jws)
        }
    }

    /// Scansione bloccante per Siri/App Intents: esegue tutta la pipeline
    /// (aggiornando anche lo stato dell'app) e ritorna la risposta.
    func scanAndAnswer(center: CLLocationCoordinate2D,
                       tier: SubscriptionTier,
                       jws: String?) async -> ParkingSpot? {
        cancel()
        scanID = UUID()
        await runInternal(center: center, tier: tier, jws: jws)
        return bestSpot
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if isSearching { phase = .idle }
    }

    func reset() {
        cancel()
        spots = []
        insight = nil
        errorMessage = nil
        phase = .idle
        scanCenter = nil
    }

    // MARK: - Pipeline

    private func runInternal(center: CLLocationCoordinate2D, tier: SubscriptionTier, jws: String?) async {
        let start = Date()
        let deadline = start.addingTimeInterval(tier.answerBudget)   // LA promessa: 20 / 10 / 5 s
        let myScan = scanID

        phase = .looking
        spots = []
        insight = nil
        errorMessage = nil
        scanCenter = center
        scanRadius = tier.searchRadius

        // ── 1: fonti reali in parallelo, IN FLUSSO.
        //
        // La promessa del piano (1 s su Ultra+) vale per il VERDETTO, non
        // per le fonti. Il flusso porta i parziali appena atterrano: Apple
        // in mezzo secondo, OSM (strisce, viali, poligoni) qualche secondo
        // dopo — e ogni lotto entra in mappa da solo. Il verdetto esce al
        // budget con quello che c'è; per i piani veloci, Claude parte a
        // fonti COMPLETE così ragiona sui dati veri, non sui primi POI.
        var collected: [ParkingSpot] = []
        let radius = tier.searchRadius

        let sourcesWindow: TimeInterval = max(9, tier.answerBudget - 0.8)
        let progress = SpotProgressBox()
        let streamDone = StreamDoneFlag()

        Task { [weak self] in
            let stream = await StreetFinder.shared.collectStream(near: center, radius: radius,
                                                                 window: sourcesWindow)
            for await batch in stream {
                await progress.set(batch)
                await self?.applyLateSpots(batch, for: myScan, tier: tier)
            }
            await streamDone.mark()
            // Piani veloci: Claude parte ORA, sui dati completi.
            if tier != .free && tier.answerBudget < 5 {
                await self?.lateClaude(for: myScan, tier: tier, jws: jws)
            }
        }

        let window = tier.answerBudget >= 5
            ? max(2.0, tier.answerBudget - 0.8)
            : max(0.55, tier.answerBudget - 0.35)

        // Istantanea al budget; se ancora vuota, una piccola grazia per il
        // primo lotto (Apple arriva quasi sempre entro 1,5 s).
        let budgetEnd = Date().addingTimeInterval(window)
        while Date() < budgetEnd {
            if await !(progress.get()).isEmpty { break }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if await (progress.get()).isEmpty {
            let grace = Date().addingTimeInterval(2.5)
            while Date() < grace {
                if await !(progress.get()).isEmpty { break }
                if await streamDone.isSet() { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        collected = await progress.get()
        if Task.isCancelled { phase = .idle; return }

        // ── 2: geometria + dedup + limiti tier
        phase = .measuring
        let unique = await StreetFinder.shared.merge(collected, tier: tier)
        if Task.isCancelled { phase = .idle; return }

        // ── 3: modello locale
        phase = .scoring
        let now = Date()
        var enriched: [ParkingSpot] = []
        for var spot in unique {
            let p = AvailabilityPredictor.shared.predict(for: spot, at: now)
            spot.availability = p.probability
            spot.availabilityReasoning = p.reasoning
            enriched.append(spot)
        }
        enriched = weightedSort(enriched)
        spots = enriched   // la mappa può già rivelare

        // ── GARANZIA: un parcheggio si trova. Punto.
        // Se nel raggio non c'è nulla: 1) allargo la ricerca, 2) se ancora
        // niente, stimo la sosta a bordo strada sulle vie residenziali.
        // Qui il budget si rompe di proposito: meglio una risposta in
        // ritardo che nessuna risposta.
        let sourcesFinished = await streamDone.isSet()
        if enriched.isEmpty && sourcesFinished && !Task.isCancelled {
            phase = .widening
            let wideRadius = min(3000, max(1200, radius * 1.7))
            var extra = await StreetFinder.shared.collect(near: center, radius: wideRadius,
                                                          window: max(window, 4))
            if extra.isEmpty {
                extra = await StreetFinder.shared.estimatedKerbside(near: center,
                                                                    radius: min(wideRadius, 1200), budget: 4)
            }
            if Task.isCancelled { phase = .idle; return }
            let rescued = await StreetFinder.shared.merge(extra, tier: tier)
            enriched = rescued.map { spot in
                var s = spot
                let pr = AvailabilityPredictor.shared.predict(for: s, at: now)
                s.availability = pr.probability
                s.availabilityReasoning = pr.reasoning
                if s.confidence < 0.6 {
                    s.availabilityReasoning.insert("Stima su strada residenziale (zona non mappata)", at: 0)
                }
                return s
            }
            enriched = weightedSort(enriched)
            spots = enriched
            scanRadius = wideRadius
            logger.info("Salvataggio: \(enriched.count) risultati allargando a \(Int(wideRadius))m")
        }

        // ── 4: il verdetto. Prima un giudizio locale IMMEDIATO per TUTTI
        //       i tier (Neural Engine se c'è, euristica WITP se no): l'app
        //       risponde sempre, anche offline o col backend giù. Poi, per i
        //       tier a pagamento, Claude — in tempo se ce la fa, altrimenti
        //       arriva dopo e rifinisce.
        if !enriched.isEmpty {
            phase = .choosing

            let slot = max(0.30, min(1.5, deadline.timeIntervalSinceNow - 0.05))
            if let pick = await withTimeout(slot, { await NeuralReasoner.shared.quickPick(spots: enriched) }) ?? nil,
               pick.index < enriched.count {
                insight = ClaudeInsight(summary: pick.reason,
                                        bestSpotID: enriched[pick.index].id,
                                        modelLabel: pick.onDevice ? "Neural Engine" : "WITP Engine",
                                        adjustments: [:])
                logger.info("Verdetto locale pronto (\(pick.onDevice ? "Neural Engine" : "euristica"))")
            }

            guard tier != .free else {
                if Task.isCancelled { phase = .idle; return }
                finalize(enriched, tier: tier, center: center, start: start)
                return
            }

            if tier.answerBudget >= 5 {
                let fullTimeout: TimeInterval
                switch tier {
                case .free, .premium: fullTimeout = 16
                case .turbo, .ultra:  fullTimeout = 12
                case .ultraPlus:      fullTimeout = 10
                }
                let claudeTask = Task {
                    await ClaudeReasoner.shared.analyze(spots: enriched, tier: tier,
                                                        jws: jws, timeout: fullTimeout)
                }

                let remaining = deadline.timeIntervalSinceNow
                var verdict: ClaudeInsight? = nil
                if remaining > 0.6 {
                    verdict = await withTimeout(remaining) { await claudeTask.value } ?? nil
                }
                if Task.isCancelled { phase = .idle; return }

                if let verdict {
                    enriched = merged(enriched, with: verdict)
                    spots = enriched
                    insight = verdict
                    logger.info("Claude in tempo: \(verdict.adjustments.count) spot raffinati")
                } else {
                    logger.info("Budget \(tier.answerBudget)s: risposta locale ora, Claude rifinisce")
                    Task { [weak self] in
                        if let late = await claudeTask.value {
                            await self?.applyLateInsight(late, for: myScan)
                        }
                    }
                }
            }
            // Piani veloci (<5 s): Claude è già programmato a fonti complete.
        }

        // ── fine: la risposta, entro il budget. Sempre.
        finalize(enriched, tier: tier, center: center, start: start)
    }

    private func finalize(_ result: [ParkingSpot], tier: SubscriptionTier,
                          center: CLLocationCoordinate2D, start: Date) {
        lastResult = ParkingScanResult(startedAt: start, finishedAt: Date(),
                                       spots: result, tier: tier, center: center)
        if result.isEmpty {
            errorMessage = "Nessun parcheggio mappato qui vicino."
        }
        phase = .done
        logger.info("Risposta con \(result.count) parcheggi in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }

    /// Le fonti sono atterrate dopo il verdetto (piani veloci): la mappa
    /// si riempie ORA — strisce, poligoni, viali — senza buttare la
    /// risposta già data. Se Claude ha già parlato, i suoi aggiustamenti
    /// restano applicati.
    private func applyLateSpots(_ collected: [ParkingSpot], for scan: UUID,
                                tier: SubscriptionTier) async {
        guard scan == scanID, !collected.isEmpty, !Task.isCancelled else { return }
        let unique = await StreetFinder.shared.merge(collected, tier: tier)
        // Aggiorna se ci sono più parcheggi, MA ANCHE se lo stesso numero di
        // posti ora ha più STRISCE disegnate: al secondo 1 arrivano le
        // pillole Apple, poi OSM porta gli stessi posti ma DISEGNATI. Il
        // conteggio non cambia → prima usciva qui e le strisce non
        // comparivano mai. Ora conta anche la vernice.
        let newDrawn = unique.reduce(0) { $0 + ($1.stripes.isEmpty ? 0 : 1) }
        let curDrawn = spots.reduce(0) { $0 + ($1.stripes.isEmpty ? 0 : 1) }
        let newStripes = unique.reduce(0) { $0 + $1.stripes.count }
        let curStripes = spots.reduce(0) { $0 + $1.stripes.count }
        guard unique.count > spots.count
                || newDrawn > curDrawn
                || newStripes > curStripes else { return }   // niente di nuovo
        let now = Date()
        var enriched: [ParkingSpot] = []
        for var spot in unique {
            let p = AvailabilityPredictor.shared.predict(for: spot, at: now)
            spot.availability = p.probability
            spot.availabilityReasoning = p.reasoning
            enriched.append(spot)
        }
        enriched = weightedSort(enriched)
        if let ins = insight { enriched = merged(enriched, with: ins) }
        // Verdetto locale (o assente) + più dati = scelta da rifare: il
        // posto migliore può stare in un lotto appena atterrato.
        if insight == nil || insight?.modelLabel.hasPrefix("Claude") != true,
           let pick = NeuralReasoner.shared.heuristicPick(spots: enriched),
           pick.index < enriched.count {
            insight = ClaudeInsight(summary: pick.reason,
                                    bestSpotID: enriched[pick.index].id,
                                    modelLabel: pick.onDevice ? "Neural Engine" : "WITP Engine",
                                    adjustments: insight?.adjustments ?? [:])
        }
        spots = enriched
        logger.info("Fonti in ritardo: mappa completata con \(enriched.count) parcheggi")
    }

    /// Piani veloci: Claude parte quando le fonti hanno finito, così il
    /// suo ragionamento vede TUTTO (strisce, viali, poligoni), non i soli
    /// POI del primo secondo.
    private func lateClaude(for scan: UUID, tier: SubscriptionTier, jws: String?) async {
        guard scan == scanID, !spots.isEmpty, !Task.isCancelled else { return }
        let timeout: TimeInterval = tier == .ultraPlus ? 10 : 12
        if let verdict = await ClaudeReasoner.shared.analyze(spots: spots, tier: tier,
                                                             jws: jws, timeout: timeout) {
            applyLateInsight(verdict, for: scan)
        }
    }

    /// Claude è arrivato dopo il budget: rifinisce la risposta già in mano
    /// all'utente — solo se la scansione è ancora quella corrente.
    private func applyLateInsight(_ verdict: ClaudeInsight, for scan: UUID) {
        guard scan == scanID, phase == .done, !spots.isEmpty else { return }
        spots = merged(spots, with: verdict)
        insight = verdict
        if let last = lastResult {
            lastResult = ParkingScanResult(startedAt: last.startedAt, finishedAt: Date(),
                                           spots: spots, tier: last.tier, center: last.center)
        }
        HapticManager.tap()
        logger.info("Claude ha rifinito la risposta dopo il budget")
    }

    private func merged(_ input: [ParkingSpot], with verdict: ClaudeInsight) -> [ParkingSpot] {
        let out = input.map { spot in
            var spot = spot
            if let adj = verdict.adjustments[spot.id] {
                spot.availability = adj.probability
                spot.availabilityReasoning.insert(adj.reason, at: 0)
            }
            return spot
        }
        return weightedSort(out)
    }

    /// Punteggio: disponibilità (60%) + vicinanza (40%).
    private func weightedSort(_ input: [ParkingSpot]) -> [ParkingSpot] {
        input.sorted { a, b in
            (a.availability * 0.6 + (1 - min(1, a.distanceFromUser / 1500)) * 0.4) >
            (b.availability * 0.6 + (1 - min(1, b.distanceFromUser / 1500)) * 0.4)
        }
    }
}


// MARK: - Corsa contro il tempo

/// Esegue `operation` con un tetto massimo di secondi: se scade, nil.
/// (Il task sottostante, se esterno, continua: serve per la rifinitura tardiva.)
nonisolated func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}


// MARK: - Appoggi del flusso fonti

/// Ultimo lotto di parcheggi arrivato dal flusso, letto in modo sicuro.
private actor SpotProgressBox {
    private var value: [ParkingSpot] = []
    func set(_ v: [ParkingSpot]) { value = v }
    func get() -> [ParkingSpot] { value }
}

/// Flag: il flusso delle fonti è terminato.
private actor StreamDoneFlag {
    private var done = false
    func mark() { done = true }
    func isSet() -> Bool { done }
}
