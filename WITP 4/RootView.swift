//
//  RootView.swift
//  WITP
//
//  Una sola schermata. Tutto il resto (profilo, soste, piani) vive
//  in sheet richiamati da lì. Niente tab bar: la mappa È l'app.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        WITPMapView()
    }
}
