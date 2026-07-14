//
//  BoardView.swift
//  Trainly
//
//  Tabellone partenze/arrivi: l'utente sceglie la stazione.
//  Ricerca con autocompletamento + sezioni Recenti e Principali.
//

internal import SwiftUI

struct BoardView: View {
    
    @StateObject private var stations = StationsStore()
    @State private var query: String = ""
    @State private var selectedStation: RFIStation?
    @FocusState private var searchFocused: Bool
    
    private var results: [RFIStation] {
        stations.search(query)
    }
    
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            // MARK: - Barra di ricerca
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Cerca stazione...", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .autocorrectionDisabled(true)
                    .textContentType(.jobTitle)

                
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(14)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .padding(.top, 8)
            
            // MARK: - Lista stazioni
            List {
                if isSearching {
                    if results.isEmpty {
                        Text("Nessuna stazione trovata")
                            .foregroundColor(.secondary)
                    } else {
                        Section {
                            ForEach(results) { stationRow($0) }
                        }
                    }
                } else {
                    if !stations.recents.isEmpty {
                        Section("Recenti") {
                            ForEach(stations.recents) { stationRow($0) }
                        }
                    }
                    Section("Principali") {
                        ForEach(stations.principali) { stationRow($0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationDestination(item: $selectedStation) { station in
            StationBoardView(station: station)
        }
    }
    
    // MARK: - Riga stazione
    
    private func stationRow(_ station: RFIStation) -> some View {
        Button {
            select(station)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "building.columns")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(station.displayName)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func select(_ station: RFIStation) {
        searchFocused = false
        stations.addRecent(station)
        query = ""
        selectedStation = station
    }
}

#Preview {
    NavigationStack {
        BoardView()
            .environmentObject(AppRouter())
    }
}
