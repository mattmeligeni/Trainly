//
//  TrainService.swift
//  Trainly
//
//  Dispatcher che sceglie il service corretto in base al vettore.
//  Usato da ricerca, pull-to-refresh e apertura dei preferiti.
//

import Foundation

enum TrainServiceError: Error {
    case unsupportedVector
}

enum TrainService {

    /// Scarica il percorso per il vettore indicato (stringa come in `vector.rawValue`).
    static func fetch(vector: String, numero: String) async throws -> TrainJourney {
        switch vector {
        case "Italo":
            return try await ItaloService.journey(numeroTreno: numero)
        case "Trenitalia":
            return try await TrenitaliaService.journey(numeroTreno: numero)
        case "Trenord":
            return try await TrenordService.journey(numeroTreno: numero)
        default:
            throw TrainServiceError.unsupportedVector
        }
    }

    /// Variante che restituisce nil in caso di errore (comoda per il refresh).
    static func reload(vector: String, numero: String) async -> TrainJourney? {
        try? await fetch(vector: vector, numero: numero)
    }
}

// MARK: - Motivo di un caricamento fallito

/// Perché un treno non si è caricato: "non trovato" va distinto da offline e
/// server in errore, altrimenti l'utente crede che il treno non esista.
enum TrainLoadFailure: Equatable {
    case offline
    case notFound
    case server

    /// nil se la richiesta è stata annullata (una più recente l'ha sostituita).
    init?(_ error: Error) {
        if error is CancellationError { return nil }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled:
                return nil
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                self = .offline
            default:
                self = .server
            }
            return
        }
        switch error {
        case TrenitaliaError.trainNotFound, ItaloError.trainNotFound, TrenordError.trainNotFound:
            self = .notFound
        default:
            self = .server
        }
    }

    var title: String {
        switch self {
        case .offline: return "Nessuna connessione"
        case .notFound: return "Treno non trovato"
        case .server: return "Servizio non raggiungibile"
        }
    }

    var message: String {
        switch self {
        case .offline:
            return "Controlla la connessione a Internet e riprova."
        case .notFound:
            return "Nessun treno in circolazione con questo numero."
        case .server:
            return "Il servizio del vettore non risponde o ha dato una risposta non valida. Riprova tra poco."
        }
    }

    var systemImage: String {
        switch self {
        case .offline: return "wifi.slash"
        case .notFound: return "magnifyingglass"
        case .server: return "exclamationmark.icloud"
        }
    }

    /// Riprovare ha senso solo per guasti temporanei.
    var canRetry: Bool {
        self == .offline || self == .server
    }
}
