//
//  BoardView.swift
//  Trainly
//
//  Tabellone partenze/arrivi: l'utente sceglie la stazione.
//  Ricerca con autocompletamento + sezioni Preferite, Recenti e Principali.
//

internal import SwiftUI

struct BoardView: View {

    @StateObject private var stations = StationsStore()
    @State private var query: String = ""
    @State private var selectedStation: RFIStation?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Dove compare la riga: decide le azioni di swipe disponibili.
    private enum RowContext {
        case search, favorite, recent, principal
    }

    var body: some View {
        // Calcolato una volta per render (prima la ricerca girava due volte).
        let results = isSearching ? stations.search(query) : []

        VStack(spacing: 0) {

            // MARK: - Barra di ricerca
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                TextField("Cerca stazione...", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .autocorrectionDisabled(true)
                    // Invio sulla tastiera: apre il primo risultato.
                    .onSubmit {
                        if let first = results.first { select(first) }
                    }
                    .frame(minHeight: 44)


                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            // Area di tocco di almeno 44 pt.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancella ricerca")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, query.isEmpty ? 14 : 2)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .padding(.top, 8)

            // MARK: - Lista stazioni
            List {
                if isSearching {
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(results) { stationRow($0, context: .search) }
                        }
                    }
                } else {
                    if !stations.favorites.isEmpty {
                        Section("Preferite") {
                            ForEach(stations.favorites) { stationRow($0, context: .favorite) }
                        }
                    }
                    if !stations.recents.isEmpty {
                        Section("Recenti") {
                            ForEach(stations.recents) { stationRow($0, context: .recent) }
                        }
                    }
                    Section("Principali") {
                        ForEach(stations.principali) { stationRow($0, context: .principal) }
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

    private func stationRow(_ station: RFIStation, context: RowContext) -> some View {
        let isFavorite = stations.isFavorite(station)
        return Button {
            select(station)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: context == .favorite ? "star.fill" : "building.columns")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(station.displayName)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
        }
        // Swipe a sinistra: preferita; a destra: rimuovi (preferite e recenti).
        // Le azioni di swipe sono anche azioni VoiceOver.
        .swipeActions(edge: .leading) {
            Button {
                stations.toggleFavorite(station)
            } label: {
                Label(isFavorite ? "Rimuovi dalle preferite" : "Aggiungi alle preferite",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if context == .recent {
                Button(role: .destructive) {
                    stations.removeRecent(station)
                } label: {
                    Label("Rimuovi dalle recenti", systemImage: "trash")
                }
            } else if context == .favorite {
                Button(role: .destructive) {
                    stations.toggleFavorite(station)
                } label: {
                    Label("Rimuovi dalle preferite", systemImage: "star.slash")
                }
            }
        }
        .contextMenu {
            Button {
                stations.toggleFavorite(station)
            } label: {
                Label(isFavorite ? "Rimuovi dalle preferite" : "Aggiungi alle preferite",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            if context == .recent {
                Button(role: .destructive) {
                    stations.removeRecent(station)
                } label: {
                    Label("Rimuovi dalle recenti", systemImage: "trash")
                }
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
