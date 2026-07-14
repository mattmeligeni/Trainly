//
//  StationsStore.swift
//  Trainly
//
//  Elenco stazioni RFI (da StazioniRFI.swift) + ricerca, recenti e principali.
//

import Foundation
internal import Combine

// MARK: - Modello stazione

struct RFIStation: Identifiable, Hashable, Codable {
    let name: String    // nome RFI in ALL CAPS, es. "MILANO CENTRALE"
    let code: String    // placeId per il monitor RFI, es. "1728"

    var id: String { code }

    /// Nome leggibile (Title Case) per la UI.
    var displayName: String { name.capitalized }
}

// MARK: - Store

@MainActor
final class StationsStore: ObservableObject {

    /// Ultime stazioni scelte (persistite).
    @Published private(set) var recents: [RFIStation] = []

    /// Tutte le stazioni, ordinate per nome.
    let all: [RFIStation]

    /// Stazioni principali per accesso rapido.
    let principali: [RFIStation] = [
        RFIStation(name: "MILANO CENTRALE", code: "1728"),
        RFIStation(name: "BOLOGNA C.LE/AV", code: "942"),
        RFIStation(name: "ROMA TERMINI", code: "2416"),
        RFIStation(name: "FIRENZE SANTA MARIA NOVELLA", code: "1325"),
        RFIStation(name: "BARI CENTRALE", code: "595"),
    ]

    private let recentsKey = "recentStations"
    private let maxRecents = 5

    init() {
        all = stationIDs
            .map { RFIStation(name: $0.key, code: $0.value) }
            .sorted { $0.name < $1.name }
        loadRecents()
    }

    /// Filtra le stazioni per sottostringa (case-insensitive).
    func search(_ query: String) -> [RFIStation] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else { return [] }
        // Prima i match che iniziano con la query, poi gli altri.
        let matches = all.filter { $0.name.contains(q) }
        return matches.sorted {
            let a = $0.name.hasPrefix(q), b = $1.name.hasPrefix(q)
            if a != b { return a }
            return $0.name < $1.name
        }
    }

    /// Registra una stazione tra le recenti (in cima, senza duplicati).
    func addRecent(_ station: RFIStation) {
        recents.removeAll { $0.code == station.code }
        recents.insert(station, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        saveRecents()
    }

    // MARK: - Persistenza

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([RFIStation].self, from: data) else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }
}
