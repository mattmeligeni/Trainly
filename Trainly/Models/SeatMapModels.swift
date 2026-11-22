//
//  SeatMapModels.swift
//  Trainly
//
//  Mappa dei posti Trenitalia (lefrecce, BFF del sito web). Flusso:
//   1. ticket/solutions tra due fermate -> cartId + soluzione del treno cercato
//   2. (opzionale) grid/{cartId}/update -> cambia la classe (offerta) selezionata
//   3. seatmap/{cartId}?solutionId&nodeId -> carrozze della classe selezionata
//  Nessun acquisto e nessuna prenotazione: la mappa si legge subito dopo la ricerca.
//

import Foundation

// MARK: - Ricerca (solo i campi necessari alla mappa)

struct SeatSearchResponse: Decodable {
    let cartId: String?
    let solutions: [SeatSearchSolution]?
}

struct SeatSearchSolution: Decodable {
    let solution: SeatSolutionInfo?
    let grids: [SeatGrid]?
    let canShowSeatMap: Bool?
}

struct SeatSolutionInfo: Decodable {
    let id: String?
    let status: String?             // SALEABLE | NOT_SALEABLE | SOLD_OUT | INHIBITED
    let trains: [SeatTrain]?
    let nodes: [SeatNode]?
}

struct SeatTrain: Decodable {
    let name: String?               // numero treno, es. "9311"
}

struct SeatNode: Decodable {
    let id: String?
}

struct SeatGrid: Decodable {
    let selectedServiceId: Int?
    let services: [SeatGridService]?
}

struct SeatGridService: Decodable {
    let id: Int?
    let name: String?
    let offers: [SeatGridOffer]?
}

struct SeatGridOffer: Decodable {
    let status: String?
    let price: RawPrice?
    let offerKeys: [String]?
    let travellers: [SeatTraveller]?
}

struct SeatTraveller: Decodable {
    let id: String?
}

// MARK: - Mappa posti

struct SeatMapResponse: Decodable {
    let wagons: [SeatWagon]?
    let selectionType: String?      // ALLOWED | NOT_ALLOWED | AUTOMATICALLY_ASSIGNED
}

struct SeatWagon: Decodable, Identifiable, Hashable {
    let id: String                  // numero carrozza
    let image: SeatShape?           // dimensioni della carrozza (sistema di coordinate)
    let available: Bool?
    let seats: [Seat]?
    let additionalIcons: [SeatShape]?

    /// Solo i posti con una posizione: quelli che si disegnano. Così contatore e
    /// mappa coincidono.
    var drawableSeats: [Seat] { (seats ?? []).filter { $0.image?.isDrawable == true } }
    var freeCount: Int { drawableSeats.filter { $0.available == true }.count }
    var totalCount: Int { drawableSeats.count }
}

struct Seat: Decodable, Hashable {
    let label: String?              // es. "1D"
    let number: String?
    let image: SeatShape?           // posizione nella carrozza
    let available: Bool?
}

/// Rettangolo nel sistema di coordinate della carrozza (punto in alto a sinistra).
/// `id` identifica il tipo di elemento per le icone aggiuntive (tavolo, WC, bici…).
struct SeatShape: Decodable, Hashable {
    let id: String?
    let width: Double?
    let height: Double?
    let x: Double?
    let y: Double?
    let rotation: Double?

    var isDrawable: Bool {
        guard x != nil, y != nil, let width, let height else { return false }
        return width > 0 && height > 0
    }
}

// MARK: - Modelli per la UI

/// Classe di viaggio della soluzione (Standard, Premium, 1ª classe…). Senza
/// offerKeys la classe è esaurita: lefrecce non restituisce le sue carrozze.
struct SeatClass: Identifiable, Hashable {
    let id: Int                     // serviceId
    let name: String
    let minPrice: Double?
    let offerKeys: [String]
    let travellerIds: [String]

    var isAvailable: Bool { !offerKeys.isEmpty }
}

/// Carrozza della composizione completa, con la classe a cui appartiene.
struct ClassedWagon: Identifiable, Hashable {
    let wagon: SeatWagon
    let className: String
    var id: String { wagon.id }
}

/// Mappa completa del treno sulla tratta: tutte le classi disponibili unite.
struct FullSeatMap {
    let wagons: [ClassedWagon]      // ordinate per numero carrozza
    let soldOutClasses: [String]    // classi esaurite (nessuna mappa disponibile)
    let selectionAllowed: Bool      // false = posti assegnati automaticamente

    var freeCount: Int { wagons.reduce(0) { $0 + $1.wagon.freeCount } }
    var totalCount: Int { wagons.reduce(0) { $0 + $1.wagon.totalCount } }
}

/// Riferimenti lefrecce del treno sulla tratta scelta, riusati per caricare la
/// mappa e per cambiare classe.
struct SeatMapContext: Hashable {
    let cartId: String
    let solutionId: String
    let nodeId: String
    let classes: [SeatClass]
    let defaultClassId: Int?
}

/// Vettore della mappa posti (lefrecce per Trenitalia, app Italo per Italo).
enum SeatMapCarrier: Hashable { case trenitalia, italo }

enum SeatMapError: Error, Equatable {
    case stationNotSupported        // fermata senza codice/ID lefrecce
    case trainNotFound              // il treno non compare tra le soluzioni
    case notSaleable(String)        // già partito o a ridosso della partenza
    case noSeatMap                  // treno senza posti assegnati (es. regionali)
    case network
}

/// Tipi di icona aggiuntiva nella carrozza (id dal sito lefrecce).
enum SeatIconKind {
    case table, wc, accessibleWC, wheelchair, stroller, luggage, bike, bar, area, kids, staff, hidden

    init(id: String?) {
        switch Int(id ?? "") ?? -1 {
        case 0, 13, 25: self = .table
        case 16, 216: self = .wc
        case 23, 223: self = .accessibleWC
        case 4, 204: self = .wheelchair
        case 19, 219: self = .stroller
        case 20, 220: self = .luggage
        case 21, 24, 151...154, 221, 224, 251...254: self = .bike
        case 3, 125, 126, 203, 225, 226: self = .bar
        case 2, 202: self = .area
        case 155, 255: self = .kids
        case 33: self = .staff
        default: self = .hidden        // delimitatori, minimappa, separatori
        }
    }

    var symbol: String? {
        switch self {
        case .table, .hidden: return nil
        case .wc: return "toilet.fill"
        case .accessibleWC, .wheelchair: return "figure.roll"
        case .stroller: return "stroller.fill"
        case .luggage: return "suitcase.fill"
        case .bike: return "bicycle"
        case .bar: return "cup.and.saucer.fill"
        case .area: return "person.3.fill"
        case .kids: return "figure.and.child.holdinghands"
        case .staff: return "person.fill"
        }
    }
}
