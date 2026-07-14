//
//  trenitaliaRequest.swift
//  Trainly
//
//  Servizio ViaggiaTreno (Trenitalia).
//  La ricerca avviene in due passaggi:
//   1. cercaNumeroTrenoTrenoAutocomplete/<numero> -> stringa con codice origine e timestamp
//   2. andamentoTreno/<codOrigine>/<numero>/<timestamp> -> JSON con l'andamento reale
//

import Foundation

// MARK: - Errori
enum TrenitaliaError: Error {
    case invalidURL
    case invalidResponse
    case trainNotFound
    case decodingFailed(Error)
}

// MARK: - Riferimento treno (risultato autocomplete)
struct TrenitaliaTrainRef {
    let numero: String       // es. "8509"
    let codOrigine: String   // es. "S11811"
    let timestamp: Int       // es. 1783807200000 (ms)
    let descrizione: String  // es. "SIBARI - 12/07/26"
}

// MARK: - Servizio
enum TrenitaliaService {

    private static let baseURL = "http://www.viaggiatreno.it/infomobilitamobile/resteasy/viaggiatreno/"

    /// Percorso normalizzato pronto per la UI (TrainView). Usa la corsa di oggi.
    static func journey(numeroTreno: String) async throws -> TrainJourney {
        let refs = try await cercaNumeriTreno(numeroTreno)
        guard let ref = bestRef(refs) else { throw TrenitaliaError.trainNotFound }
        return try await journey(from: ref)
    }

    /// Tra più corse sceglie quella con data di partenza più vicina a oggi.
    static func bestRef(_ refs: [TrenitaliaTrainRef]) -> TrenitaliaTrainRef? {
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        return refs.min {
            abs(Double($0.timestamp) - todayStart) < abs(Double($1.timestamp) - todayStart)
        }
    }

    static func exact(_ ref: TrenitaliaTrainRef) -> ExactTrenitaliaRef {
        ExactTrenitaliaRef(codOrigine: ref.codOrigine, numero: ref.numero, timestamp: ref.timestamp)
    }

    /// Journey della corsa di oggi + eventuali altre date della stessa corsa
    /// (stessa origine) per il picker. Usato aprendo un treno per numero.
    static func detail(numeroTreno: String) async throws -> (journey: TrainJourney, currentRef: ExactTrenitaliaRef, dateOptions: [ExactTrenitaliaRef]) {
        let refs = try await cercaNumeriTreno(numeroTreno)
        guard let today = bestRef(refs) else { throw TrenitaliaError.trainNotFound }
        let journey = try await journey(from: today)

        let groups = Dictionary(grouping: refs, by: { $0.codOrigine })
        var dates: [ExactTrenitaliaRef] = []
        if groups.count == 1, let group = groups.values.first, group.count > 1 {
            dates = group.sorted { $0.timestamp < $1.timestamp }.map(exact)
        }
        return (journey, exact(today), dates)
    }

    /// Altre date della stessa corsa (stessa origine); vuoto se è unica.
    static func dateOptions(numero: String, origine: String,
                            including ref: ExactTrenitaliaRef) async -> [ExactTrenitaliaRef] {
        guard let refs = try? await cercaNumeriTreno(numero) else { return [] }
        var same = refs.filter { $0.codOrigine == origine }.map(exact)
        if !same.contains(ref) { same.append(ref) }
        guard same.count > 1 else { return [] }
        return same.sorted { $0.timestamp < $1.timestamp }
    }

    /// Percorso normalizzato per una specifica corsa (ref dall'autocomplete).
    static func journey(from ref: TrenitaliaTrainRef) async throws -> TrainJourney {
        try await TrainJourney(trenitalia: andamento(ref: ref))
    }

    /// Risposta grezza `andamentoTreno` per la corsa indicata.
    static func andamento(ref: TrenitaliaTrainRef) async throws -> TrenitaliaResponse {
        guard let url = URL(string: "\(baseURL)andamentoTreno/\(ref.codOrigine)/\(ref.numero)/\(ref.timestamp)") else {
            throw TrenitaliaError.invalidURL
        }
        let data = try await get(url)
        do {
            return try JSONDecoder().decode(TrenitaliaResponse.self, from: data)
        } catch {
            throw TrenitaliaError.decodingFailed(error)
        }
    }

    // MARK: - Passo 1: autocomplete

    /// Risolve il numero treno in una o più corse (codice origine + timestamp).
    /// Risposta (una riga per corsa):
    /// "20 - COCQUIO TREVISAGO - 12/07/26|20-S01744-1783807200000"
    /// "20 - MILANO CENTRALE - 12/07/26|20-S01700-1783807200000"
    static func cercaNumeriTreno(_ numeroTreno: String) async throws -> [TrenitaliaTrainRef] {
        let numero = numeroTreno.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(baseURL)cercaNumeroTrenoTrenoAutocomplete/\(numero)") else {
            throw TrenitaliaError.invalidURL
        }

        let data = try await get(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TrenitaliaError.invalidResponse
        }

        let refs = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(parseRef)

        guard !refs.isEmpty else { throw TrenitaliaError.trainNotFound }
        return refs
    }

    /// Converte una riga dell'autocomplete in un TrenitaliaTrainRef.
    private static func parseRef(_ line: String) -> TrenitaliaTrainRef? {
        guard line.contains("|") else { return nil }
        let parts = line.components(separatedBy: "|")
        let descrizione = parts[0].trimmingCharacters(in: .whitespaces)

        // parte 2: "20-S01744-1783807200000"
        let ids = parts[1].components(separatedBy: "-")
        guard ids.count >= 3,
              let timestamp = Int(ids[2].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        return TrenitaliaTrainRef(
            numero: ids[0].trimmingCharacters(in: .whitespaces),
            codOrigine: ids[1].trimmingCharacters(in: .whitespaces),
            timestamp: timestamp,
            descrizione: descrizione
        )
    }

    // MARK: - GET helper

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TrenitaliaError.invalidResponse
        }
        return data
    }
}
