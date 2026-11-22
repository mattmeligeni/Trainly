//
//  trenordRequest.swift
//  Trainly
//
//  Servizio Trenord: andamento di un treno dall'API dell'app Trenord
//  (cloud.mp.trenord.it/train/{numero}), JSON in chiaro come array
//  [TrenordSolution] (vedi TrenordModels.swift). Stesso host e stesso header
//  `secret` della ricerca biglietti (TrenordTicketAPI). Prima si usava il BFF
//  del sito (www.trenord.it/mia/bff), con la risposta cifrata AES-256-ECB.
//

import Foundation

// MARK: - Errori
enum TrenordError: Error {
    case invalidURL
    case invalidResponse
    case trainNotFound
    case decodingFailed(Error)
}

// MARK: - Servizio Trenord
enum TrenordService {

    private static let baseURL = "https://cloud.mp.trenord.it/train/"

    /// Percorso normalizzato pronto per la UI (TrainView). L'API restituisce la
    /// corsa in circolazione (o l'ultima del giorno): non accetta una data.
    static func journey(numeroTreno: String) async throws -> TrainJourney {
        let response = try await soluzioni(trainId: numeroTreno)
        guard let journey = TrainJourney(trenord: response) else {
            throw TrenordError.trainNotFound
        }
        return journey
    }

    /// Scarica e decodifica l'andamento del treno. Un numero sconosciuto dà `[]`.
    static func soluzioni(trainId: String) async throws -> TrenordResponse {
        let numero = trainId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !numero.isEmpty,
              let encoded = numero.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + encoded) else {
            throw TrenordError.invalidURL
        }

        var request = TrenordTicketAPI.request(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("it-IT", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TrenordError.invalidResponse
        }

        let decoded: TrenordResponse
        do {
            decoded = try JSONDecoder().decode(TrenordResponse.self, from: data)
        } catch {
            throw TrenordError.decodingFailed(error)
        }
        guard !decoded.isEmpty else { throw TrenordError.trainNotFound }
        return decoded
    }
}
