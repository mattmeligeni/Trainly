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
