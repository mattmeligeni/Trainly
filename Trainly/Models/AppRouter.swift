//
//  AppRouter.swift
//  Trainly
//
//  Coordina la navigazione tra i tab (es. dal Tabellone alla ricerca di un treno).
//

internal import Combine
internal import SwiftUI

/// Corsa Trenitalia esatta (dai link infomobilità): origine + numero + data.
struct ExactTrenitaliaRef: Equatable, Hashable {
    let codOrigine: String
    let numero: String
    let timestamp: Int
}

/// Cosa aprire in un TrainLoaderView (push nel NavigationStack della tab corrente).
enum TrainRequest: Hashable {
    case vectorNumber(vector: String, number: String)  // preferiti, tabellone
    case exactTrenitalia(ExactTrenitaliaRef)            // link infomobilità
}

/// Destinazioni nel tab Utilità.
enum UtilityDestination: Hashable {
    case infomobilita
    case scioperi
    case biglietti
}

struct PendingSearch: Equatable {
    let vector: String   // rawValue di `vector`
    let number: String
    var exactRef: ExactTrenitaliaRef? = nil   // se presente, apre esattamente quella corsa
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: MainTabView.Tab = .board
    @Published var pendingSearch: PendingSearch?
    @Published var utilityPath: [UtilityDestination] = []
    @Published var pendingInfoTrain: String?   // treno da evidenziare in infomobilità

    /// Apre l'infomobilità (tab Utilità) evidenziando l'avviso del treno indicato.
    func openInfomobilita(forTrain number: String) {
        pendingInfoTrain = number
        utilityPath = [.infomobilita]
        selectedTab = .info
    }

    /// Passa alla tab Cerca ed esegue la ricerca del treno indicato.
    func openSearch(vector: String, number: String) {
        pendingSearch = PendingSearch(vector: vector, number: number)
        selectedTab = .search
    }

    /// Apre esattamente la corsa Trenitalia indicata (link infomobilità con data).
    func openTrenitaliaExact(_ ref: ExactTrenitaliaRef) {
        pendingSearch = PendingSearch(vector: "Trenitalia", number: ref.numero, exactRef: ref)
        selectedTab = .search
    }

    /// Passa alla tab Cerca senza avviare alcuna ricerca (link generico).
    func openSearchTab() {
        pendingSearch = nil
        selectedTab = .search
    }
}
