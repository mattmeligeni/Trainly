//
//  FavoritesStore.swift
//  Trainly
//
//  Gestione treni preferiti, persistiti in UserDefaults.
//

import Foundation
internal import Combine
internal import SwiftUI

// MARK: - Modello preferito

struct FavoriteTrain: Codable, Identifiable, Hashable {
    let vector: String     // "Trenitalia" | "Italo" | "Trenord"
    let number: String
    let title: String      // es. "Trenitalia Frecciarossa 8509"
    let subtitle: String   // es. "Sibari → Bolzano"
    let category: String?  // nome imageset (es. "FRECCIAROSSA") per l'icona

    /// Identità stabile: uno stesso treno per lo stesso vettore.
    var id: String { "\(vector)-\(number)" }
}

// MARK: - Store

final class FavoritesStore: ObservableObject {

    @Published private(set) var favorites: [FavoriteTrain] = []

    private let key = "favoriteTrains"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func contains(_ id: String) -> Bool {
        favorites.contains { $0.id == id }
    }

    func toggle(_ favorite: FavoriteTrain) {
        if contains(favorite.id) {
            remove(favorite.id)
        } else {
            add(favorite)
        }
    }

    func add(_ favorite: FavoriteTrain) {
        guard !contains(favorite.id) else { return }
        favorites.append(favorite)
        save()
    }

    func remove(_ id: String) {
        favorites.removeAll { $0.id == id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Persistenza

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([FavoriteTrain].self, from: data) else {
            return
        }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: key)
    }
}
