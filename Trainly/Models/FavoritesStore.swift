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
    /// Codice stazione di origine (solo Trenitalia): lo stesso numero può indicare
    /// treni diversi. Assente nei preferiti salvati prima di questo campo.
    var originCode: String? = nil

    /// Identità stabile: uno stesso treno per lo stesso vettore (e origine, se nota).
    var id: String {
        originCode.map { "\(vector)-\(number)-\($0)" } ?? "\(vector)-\(number)"
    }

    /// Stesso treno: un preferito senza origine (vecchio formato) vale per ogni origine.
    func matches(_ other: FavoriteTrain) -> Bool {
        vector == other.vector && number == other.number
            && (originCode == nil || other.originCode == nil || originCode == other.originCode)
    }
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

    /// Come `contains(_:)`, ma riconosce anche i preferiti salvati senza origine.
    func contains(_ favorite: FavoriteTrain) -> Bool {
        favorites.contains { $0.matches(favorite) }
    }

    func toggle(_ favorite: FavoriteTrain) {
        if contains(favorite) {
            favorites.removeAll { $0.matches(favorite) }
            save()
        } else {
            add(favorite)
        }
    }

    func add(_ favorite: FavoriteTrain) {
        guard !contains(favorite) else { return }
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
