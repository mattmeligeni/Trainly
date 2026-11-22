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

/// Corsa aperta + date alternative della stessa corsa (picker in TrainView).
struct TrenitaliaDetail {
    let journey: TrainJourney
    let currentRef: ExactTrenitaliaRef
    let dateOptions: [ExactTrenitaliaRef]
}

/// Esito della ricerca per numero.
enum TrenitaliaSearchResult {
    case single(TrenitaliaDetail)
    case choices([TrenitaliaDetail])   // treni diversi con lo stesso numero
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

    /// Calendario italiano: "oggi" è quello di Roma, non quello del fuso dell'iPhone
    /// (con il telefono all'estero la corsa scelta sarebbe quella sbagliata).
    private static let romeCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome") ?? .current
        return c
    }()

    /// Tra più corse sceglie quella con data di partenza più vicina a oggi.
    static func bestRef(_ refs: [TrenitaliaTrainRef]) -> TrenitaliaTrainRef? {
        let todayStart = romeCalendar.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        return refs.min {
            abs(Double($0.timestamp) - todayStart) < abs(Double($1.timestamp) - todayStart)
        }
    }

    static func exact(_ ref: TrenitaliaTrainRef) -> ExactTrenitaliaRef {
        ExactTrenitaliaRef(codOrigine: ref.codOrigine, numero: ref.numero, timestamp: ref.timestamp)
    }

    /// Journey della corsa di oggi + eventuali altre date della stessa corsa
    /// (stessa origine) per il picker. Usato aprendo un treno per numero.
    /// Con `origine` (preferiti, recenti) apre solo il treno che parte da lì:
    /// lo stesso numero può indicare treni diversi.
    static func detail(numeroTreno: String, origine: String? = nil) async throws -> TrenitaliaDetail {
        let refs = try await refs(numero: numeroTreno, origine: origine)
        let groups = Dictionary(grouping: refs, by: { $0.codOrigine })
        if groups.count == 1, let group = groups.values.first {
            return try await detail(group: group)
        }
        // Origini diverse e nessuna nota: come prima, la corsa più vicina a oggi.
        guard let today = bestRef(refs) else { throw TrenitaliaError.trainNotFound }
        return TrenitaliaDetail(journey: try await journey(from: today),
                                currentRef: exact(today), dateOptions: [])
    }

    /// Ricerca per numero: una sola origine = stesso treno (eventualmente su più
    /// giorni); origini diverse = treni diversi, scaricati in parallelo per la scelta.
    static func search(numero: String, origine: String? = nil) async throws -> TrenitaliaSearchResult {
        let refs = try await refs(numero: numero, origine: origine)
        let groups = Dictionary(grouping: refs, by: { $0.codOrigine })
        if groups.count == 1, let group = groups.values.first {
            return .single(try await detail(group: group))
        }

        let results = await withTaskGroup(of: Result<TrenitaliaDetail, Error>.self) { tg in
            for group in groups.values {
                tg.addTask {
                    do { return .success(try await detail(group: group)) } catch { return .failure(error) }
                }
            }
            var out: [Result<TrenitaliaDetail, Error>] = []
            for await r in tg { out.append(r) }
            return out
        }
        let details = results.compactMap { try? $0.get() }
            .sorted { $0.currentRef.timestamp < $1.currentRef.timestamp }

        switch details.count {
        case 0:
            // Tutte fallite: riportiamo il motivo vero (es. offline), non "non trovato".
            for case .failure(let error) in results { throw error }
            throw TrenitaliaError.trainNotFound
        case 1:
            return .single(details[0])
        default:
            return .choices(details)
        }
    }

    /// Corse per numero, eventualmente limitate a una origine.
    private static func refs(numero: String, origine: String?) async throws -> [TrenitaliaTrainRef] {
        var refs = try await cercaNumeriTreno(numero)
        if let origine {
            refs = refs.filter { $0.codOrigine == origine }
            guard !refs.isEmpty else { throw TrenitaliaError.trainNotFound }
        }
        return refs
    }

    /// Corsa di oggi di un gruppo con la stessa origine, più le date per il picker.
    private static func detail(group: [TrenitaliaTrainRef]) async throws -> TrenitaliaDetail {
        let sameTrain = group.sorted { $0.timestamp < $1.timestamp }
        guard let today = bestRef(sameTrain) else { throw TrenitaliaError.trainNotFound }
        let journey = try await journey(from: today)
        let dates = sameTrain.count > 1 ? sameTrain.map(exact) : []
        return TrenitaliaDetail(journey: journey, currentRef: exact(today), dateOptions: dates)
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
