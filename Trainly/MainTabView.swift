//
//  MainTabView.swift
//  Trainly
//
//  Created by Mattia Meligeni on 12/07/2026.
//


internal import SwiftUI

struct MainTabView: View {
    @StateObject private var router = AppRouter()
    @AppStorage("appearance") private var appearance: String = "system"

    enum Tab {
        case board, search, info, favorites, settings
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            // 1. TABELLONE STAZIONI
            NavigationStack {
                BoardView()
                    .navigationTitle("Tabellone per Stazione")
            }
            .tabItem {
                Label("Tabellone", systemImage: "list.bullet.rectangle.portrait")
            }
            .tag(Tab.board)
            
            // 2. CERCA TRENO
            
            SearchView()
            .tabItem {
                Label("Cerca", systemImage: "magnifyingglass")
            }
            .tag(Tab.search)
            
            // 3. INFO (Infomobilità e Scioperi)
            NavigationStack(path: $router.utilityPath) {
                InfoView()
                    .navigationTitle("Utilità")
                    .navigationDestination(for: UtilityDestination.self) { dest in
                        switch dest {
                        case .infomobilita: InfomobilitaView()
                        case .scioperi: ScioperiView()
                        case .biglietti: BigliettiView()
                        }
                    }
            }
            .tabItem {
                Label("Utilità", systemImage: "square.grid.2x2")
            }
            .tag(Tab.info)

            // 4. PREFERITI
            NavigationStack {
                FavoritesView()
                    .navigationTitle("Preferiti")
            }
            .tabItem {
                Label("Preferiti", systemImage: "star.fill")
            }
            .tag(Tab.favorites)
            
            // 4. IMPOSTAZIONI
            NavigationStack {
                SettingsView()
                    .navigationTitle("Impostazioni")
            }
            .tabItem {
                Label("Impostazioni", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .environmentObject(router)
        .preferredColorScheme(colorScheme)
        // Tap globale su un punto vuoto per chiudere la tastiera ovunque.
        .background(KeyboardDismissInstaller())
    }
}

// Preview per Xcode
#Preview {
    MainTabView()
        .environmentObject(FavoritesStore())
}

