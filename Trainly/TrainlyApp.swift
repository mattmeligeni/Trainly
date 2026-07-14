//
//  TrainlyApp.swift
//  Trainly
//
//  Created by Mattia Meligeni on 12/07/2026.
//

internal import SwiftUI

@main
struct TrainlyApp: App {
    @StateObject private var favorites = FavoritesStore()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(favorites)
        }
    }
}
