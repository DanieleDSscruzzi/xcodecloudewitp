//
//  CarPlaySceneDelegate.swift
//  WITP — interfaccia CarPlay.
//
//  ═══ PRINCIPIO DI PROGETTO: LA SICUREZZA ALLA GUIDA VIENE PRIMA ═══
//
//  Chi usa questa schermata sta guidando. Ogni scelta qui sotto nasce da
//  quel vincolo, non dall'estetica:
//
//  1. ZERO DIGITAZIONE. In CarPlay non si scrive mai: niente campo di
//     ricerca, niente tastiera. Solo tocchi grandi su elementi grandi.
//  2. LA RICERCA PARTE DA SOLA. Appena l'auto si collega, WITP cerca
//     attorno alla posizione: il guidatore non deve fare nulla per avere
//     la risposta.
//  3. POCHI RISULTATI. Massimo 5, anche se ne trova 200. Una lista lunga
//     su un display in movimento è una lista che non si legge.
//  4. UNA SOLA AZIONE PER RISULTATO: "Naviga". Nessun menu, nessun
//     sottolivello, nessuna decisione complessa.
//  5. TESTI CORTI E CONCRETI. "180 m · 70% · gratis" si legge in un
//     colpo d'occhio. Le frasi lunghe restano sull'iPhone.
//  6. AVVISO ZTL BEN VISIBILE. Se un parcheggio è dentro una zona a
//     traffico limitato attiva, il display lo dice PRIMA che il
//     guidatore ci si diriga: è l'informazione che evita una multa.
//
//  Apple applica queste stesse regole in fase di revisione CarPlay ed è
//  severa: un'interfaccia che distrae viene respinta.
//

import CarPlay
import MapKit
import CoreLocation
import Combine   // legge gli ObservableObject dell'app

/// Il nome Objective-C è fissato a mano: iOS istanzia questa classe
/// leggendo la stringa dall'Info.plist, e il nome del modulo contiene uno
/// spazio ("WITP Claude"). Senza un nome esplicito, se la sostituzione
/// non combacia iOS non trova la classe e CarPlay crasha all'apertura.
@objc(WITPCarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPPointOfInterestTemplateDelegate {

    private var interfaceController: CPInterfaceController?
    private var refreshTask: Task<Void, Never>?

    /// Tetto volutamente basso: leggibilità prima di completezza.
    private let maxResults = 5

    // MARK: - Ciclo di vita

    @objc(templateApplicationScene:didConnectInterfaceController:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        // Schermata d'attesa immediata: il display non resta mai vuoto
        interfaceController.setRootTemplate(loadingTemplate(), animated: false, completion: nil)
        startSearch()
    }

    @objc(templateApplicationScene:didDisconnectInterfaceController:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        refreshTask?.cancel()
        refreshTask = nil
        self.interfaceController = nil
    }

    // MARK: - Ricerca

    /// Cerca da sola, senza che il guidatore tocchi niente.
    private func startSearch() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard let center = LocationManager.shared.currentLocation else {
                showMessage(title: "Posizione non disponibile",
                            detail: "Apri WITP sull'iPhone e consenti l'accesso alla posizione.")
                return
            }

            let tier = SubscriptionManager.shared.currentTier
            let engine = ParkingEngine.shared
            engine.run(center: center, tier: tier,
                       jws: SubscriptionManager.shared.entitlementJWS)

            // Attesa con tetto: meglio mostrare qualcosa di parziale che
            // lasciare il display fermo mentre l'auto è in movimento.
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                if engine.phase == .done { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }

            let spots = Array(engine.spots.prefix(maxResults))
            if spots.isEmpty {
                showMessage(title: "Nessun parcheggio qui",
                            detail: "Prova a ripetere la ricerca più avanti.")
            } else {
                showResults(spots, ztl: engine.ztlZones)
            }
        }
    }

    // MARK: - Schermate

    private func loadingTemplate() -> CPTemplate {
        let item = CPInformationItem(title: "Cerco parcheggio…", detail: nil)
        return CPInformationTemplate(title: "WITP",
                                     layout: .leading,
                                     items: [item],
                                     actions: [])
    }

    @MainActor
    private func showMessage(title: String, detail: String) {
        let retry = CPTextButton(title: "Riprova", textStyle: .normal) { [weak self] _ in
            guard let self else { return }
            self.interfaceController?.setRootTemplate(self.loadingTemplate(),
                                                      animated: false, completion: nil)
            self.startSearch()
        }
        let template = CPInformationTemplate(
            title: "WITP",
            layout: .leading,
            items: [CPInformationItem(title: title, detail: detail)],
            actions: [retry]
        )
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    /// I parcheggi sulla mappa CarPlay, con un solo gesto per navigare.
    @MainActor
    private func showResults(_ spots: [ParkingSpot], ztl: [ZTLZone]) {
        let pois: [CPPointOfInterest] = spots.map { spot in
            let mapItem = MKMapItem(
                location: CLLocation(latitude: spot.coordinate.latitude,
                                     longitude: spot.coordinate.longitude),
                address: nil
            )
            mapItem.name = spot.streetName

            // Riga breve: distanza, stima, tipo di zona. Leggibile a colpo d'occhio.
            let distance = spot.distanceFromUser < 1000
                ? "\(Int(spot.distanceFromUser)) m"
                : String(format: "%.1f km", spot.distanceFromUser / 1000)
            let chance = "\(Int(spot.availability * 100))%"
            var line = "\(distance) · \(chance) · \(spot.zoneType.label)"

            // AVVISO ZTL: l'informazione che evita la multa, in testa.
            let insideActiveZTL = ztl.first { $0.state.isActive && $0.contains(spot.coordinate) }
            if let zona = insideActiveZTL {
                line = "⚠️ ZTL \(zona.name) attiva · " + line
            }

            let poi = CPPointOfInterest(
                location: mapItem,
                title: spot.streetName,
                subtitle: line,
                summary: nil,
                detailTitle: spot.streetName,
                detailSubtitle: line,
                detailSummary: insideActiveZTL != nil
                    ? "Questo parcheggio è dentro una ZTL attiva in questo momento."
                    : spot.availabilityReasoning.first,
                pinImage: nil
            )

            // Unica azione possibile: avviare la navigazione.
            poi.primaryButton = CPTextButton(title: "Naviga", textStyle: .confirm) { _ in
                mapItem.openInMaps(launchOptions: [
                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
                ])
            }
            return poi
        }

        let template = CPPointOfInterestTemplate(
            title: "Parcheggi vicini",
            pointsOfInterest: pois,
            selectedIndex: 0
        )
        template.pointOfInterestDelegate = self
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Mappa spostata dal guidatore

    /// Volutamente NESSUNA azione: una mappa che si ricarica da sola mentre
    /// si guida sposta l'attenzione. La ricerca resta legata alla posizione
    /// reale dell'auto, comportamento prevedibile.
    @objc(pointOfInterestTemplate:didChangeMapRegion:)
    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate,
                                 didChangeMapRegion region: MKCoordinateRegion) {
    }
}
