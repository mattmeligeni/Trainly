//
//  italoRequest.swift
//  Trainly
//
//  Servizio Italo (italoinviaggio.italotreno.com).
//  Una sola chiamata GET con il numero treno.
//

import Foundation

enum ItaloError: Error {
    case invalidURL
    case invalidResponse
    case trainNotFound
    case decodingFailed(Error)
}

enum ItaloService {

    private static let baseURL = "https://italoinviaggio.italotreno.com/api/RicercaTrenoService"

    /// Percorso normalizzato pronto per la UI (TrainView).
    static func journey(numeroTreno: String) async throws -> TrainJourney {
        let response = try await ricerca(numeroTreno: numeroTreno)
        guard let journey = TrainJourney(italo: response) else {
            throw ItaloError.trainNotFound
        }
        return journey
    }

    /// Risposta grezza per il treno indicato.
    static func ricerca(numeroTreno: String) async throws -> ItaloResponse {
        let numero = numeroTreno.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(baseURL)?TrainNumber=\(numero)") else {
            throw ItaloError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ItaloError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(ItaloResponse.self, from: data)
        } catch {
            throw ItaloError.decodingFailed(error)
        }
    }
}
