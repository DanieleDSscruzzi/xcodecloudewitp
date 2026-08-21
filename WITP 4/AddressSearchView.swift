//
//  AddressSearchView.swift
//  WITP — cerca parcheggio dove stai andando, non solo dove sei.
//
//  Richiesta arrivata dagli utenti via WITP Care: "vorrei un campo di
//  ricerca per indirizzo, per trovare parcheggi in zone diverse dalla
//  posizione GPS attuale".
//
//  Usa MKLocalSearchCompleter, il completamento di Apple Maps: gratuito,
//  già installato su ogni iPhone, nessuna chiave API e nessun costo.
//

import SwiftUI
import MapKit
import Combine   // @Published e ObservableObject

/// Suggerimenti d'indirizzo mentre l'utente scrive.
@MainActor
final class AddressSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {

    @Published var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { results = []; return }
            completer.queryFragment = trimmed
        }
    }
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var resolving = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Indirizzi e luoghi: niente query generiche tipo "pizza"
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Centra i suggerimenti attorno all'utente: "via Roma" trova prima
    /// quella della sua città, non una a 800 km di distanza.
    func focus(on center: CLLocationCoordinate2D?) {
        guard let center else { return }
        completer.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 60_000,
            longitudinalMeters: 60_000
        )
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = Array(completer.results.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }

    /// Da suggerimento a coordinate vere.
    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        resolving = true
        defer { resolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return item.placemark.coordinate
    }

    func clear() {
        query = ""
        results = []
    }
}

/// Foglio di ricerca: scrivi un indirizzo, scegli, WITP cerca lì.
struct AddressSearchView: View {

    @StateObject private var model = AddressSearchModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    /// Posizione attuale, per dare priorità ai risultati vicini.
    let nearby: CLLocationCoordinate2D?
    /// Chiamata con le coordinate scelte: il chiamante fa partire la ricerca.
    let onPick: (CLLocationCoordinate2D, String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                WITPBackground()

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(WITPColor.textTertiary)
                        TextField("Via, piazza, città…", text: $model.query)
                            .focused($fieldFocused)
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !model.query.isEmpty {
                            Button { model.clear() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(WITPColor.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
                    .padding(.horizontal, 18)
                    .padding(.top, 10)

                    if model.results.isEmpty {
                        VStack(spacing: 10) {
                            Spacer()
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 34))
                                .foregroundStyle(WITPColor.textTertiary)
                            Text(model.query.isEmpty
                                 ? "Cerca parcheggio dove stai andando"
                                 : "Nessun risultato")
                                .font(.subheadline)
                                .foregroundStyle(WITPColor.textSecondary)
                            if model.query.isEmpty {
                                Text("Scrivi un indirizzo o il nome di un luogo:\nWITP cercherà i parcheggi lì.")
                                    .font(.caption)
                                    .foregroundStyle(WITPColor.textTertiary)
                                    .multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 30)
                    } else {
                        List(model.results, id: \.self) { item in
                            Button {
                                Task {
                                    if let coord = await model.resolve(item) {
                                        HapticManager.medium()
                                        onPick(coord, item.title)
                                        dismiss()
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.white)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(WITPColor.textSecondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }

                if model.resolving {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Cerca una zona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .onAppear {
            model.focus(on: nearby)
            fieldFocused = true
        }
    }
}
