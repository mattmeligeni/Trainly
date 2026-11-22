//
//  RecentTrainsStore.swift
//  Trainly
//
//  Ultimi treni cercati, persistiti in UserDefaults.
//

import Foundation
internal import Combine

struct RecentTrain: Codable, Identifiable, Hashable {
    let vector: String       // "Trenitalia" | "Italo" | "Trenord"
    let number: String
    let shortName: String    // es. "IC 558", "ITALO Av 9876", "Trenord 3647"
    let origin: String
    let destination: String
    /// Codice stazione di origine (solo Trenitalia): riapre proprio quel treno
    /// e non un altro con lo stesso numero. Assente nei recenti più vecchi.
    var originCode: String? = nil

    var id: String {
        originCode.map { "\(vector)-\(number)-\($0)" } ?? "\(vector)-\(number)"
    }

    /// Riga mostrata nella lista recenti.
    var line: String {
        guard !origin.isEmpty || !destination.isEmpty else { return shortName }
        return "\(shortName) - \(origin) → \(destination)"
    }
}

@MainActor
final class RecentTrainsStore: ObservableObject {
    @Published private(set) var recents: [RecentTrain] = []

    private let key = "recentTrains"
    private let maxRecents = 8

    init() { load() }

    func add(_ train: RecentTrain) {
        // Toglie anche la voce senza origine dello stesso treno (vecchio formato).
        recents.removeAll {
            $0.id == train.id
                || ($0.originCode == nil && $0.vector == train.vector && $0.number == train.number)
        }
        recents.insert(train, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        save()
    }

    func clear() {
        recents = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentTrain].self, from: data) else { return }
        recents = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
