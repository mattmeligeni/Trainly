//
//  SeatMapService.swift
//  Trainly
//
//  Mappa dei posti di un treno Trenitalia tra due fermate. Usa il BFF del sito
//  lefrecce (lo stesso della ricerca biglietti): la mappa è leggibile subito dopo
//  la ricerca, senza carrello né prenotazione. La sessione (cookie) è gestita da
//  URLSession.shared ed è necessaria: cartId e mappa sono legati alla sessione.
//

import Foundation

enum SeatMapService {

    private static let base = "https://www.lefrecce.it/Channels.Website.BFF.WEB/website"

    // MARK: - Localizzazione del treno sulla tratta

    /// Cerca il treno `trainNumber` tra le due fermate e restituisce i riferimenti
    /// per la mappa. Prova prima gli ID derivati dai codici ViaggiaTreno, poi gli
    /// ID risolti per nome (alcune stazioni hanno codici diversi, es. Bologna AV).
    static func locate(trainNumber: String, from: TrainStop, to: TrainStop) async throws -> SeatMapContext {
        guard let departure = from.scheduledDeparture else { throw SeatMapError.stationNotSupported }

        // Un minuto prima della partenza: il treno è la prima o tra le prime soluzioni.
        let time = departure.addingTimeInterval(-60)
        var tried = Set<[Int]>()
        var lastError: SeatMapError = .stationNotSupported

        func attempt(_ fromIds: [Int], _ toIds: [Int]) async throws -> SeatMapContext? {
            for fromId in fromIds {
                for toId in toIds where tried.insert([fromId, toId]).inserted {
                    try Task.checkCancellation()
                    do {
                        return try await search(trainNumber: trainNumber, fromId: fromId, toId: toId, at: time)
                    } catch let error as SeatMapError {
                        // Errori definitivi sul treno trovato: inutile provare altre stazioni.
                        if case .notSaleable = error { throw error }
                        if error == .noSeatMap || error == .network { throw error }
                        lastError = error
                    }
                }
            }
            return nil
        }

        // 1. ID derivati dai codici ViaggiaTreno (nessuna richiesta extra).
        let derivedFrom = from.stationCode.flatMap(lefrecceId(fromViaggiaTreno:)).map { [$0] } ?? []
        let derivedTo = to.stationCode.flatMap(lefrecceId(fromViaggiaTreno:)).map { [$0] } ?? []
        if let context = try await attempt(derivedFrom, derivedTo) { return context }

        // 2. Fallback: ID risolti per nome (es. "BOLOGNA C.LE/AV" -> Bologna Centrale).
        let fromIds = derivedFrom + (await resolvedId(for: from).map { [$0] } ?? [])
        let toIds = derivedTo + (await resolvedId(for: to).map { [$0] } ?? [])
        if let context = try await attempt(fromIds, toIds) { return context }
        throw lastError
    }

    /// Mappa completa: carica in sequenza le carrozze di ogni classe disponibile
    /// (la sessione ha un solo carrello, quindi niente richieste in parallelo) e le
    /// unisce in un'unica composizione ordinata per numero carrozza.
    static func fullSeatMap(_ context: SeatMapContext,
                            onProgress: @MainActor (FullSeatMap, Int, Int) -> Void = { _, _, _ in }) async throws -> FullSeatMap {
        let available = context.classes.filter(\.isAvailable)
        // Prima la classe già selezionata nel carrello: non serve cambiarla.
        let ordered = available.filter { $0.id == context.defaultClassId }
            + available.filter { $0.id != context.defaultClassId }

        var wagons: [String: ClassedWagon] = [:]
        var allowed = false
        let soldOut = context.classes.filter { !$0.isAvailable }.map(\.name)
        for (index, seatClass) in ordered.enumerated() {
            try Task.checkCancellation()
            if index > 0 || seatClass.id != context.defaultClassId {
                try await selectClass(seatClass, context: context)
            }
            let map = try await seatMap(context)
            if map.selectionType == "ALLOWED" { allowed = true }
            for wagon in map.wagons ?? [] where wagons[wagon.id] == nil {
                wagons[wagon.id] = ClassedWagon(wagon: wagon, className: seatClass.name)
            }
            // Mostra subito le classi già caricate (fino a 8 richieste in sequenza).
            onProgress(sortedMap(wagons, soldOut: soldOut, allowed: allowed), index + 1, ordered.count)
        }
        return sortedMap(wagons, soldOut: soldOut, allowed: allowed)
    }

    private static func sortedMap(_ wagons: [String: ClassedWagon], soldOut: [String], allowed: Bool) -> FullSeatMap {
        let sorted = wagons.values.sorted {
            (Int($0.wagon.id) ?? .max, $0.wagon.id) < (Int($1.wagon.id) ?? .max, $1.wagon.id)
        }
        return FullSeatMap(wagons: sorted, soldOutClasses: soldOut, selectionAllowed: allowed)
    }

    /// Mappa della classe attualmente selezionata nel carrello.
    private static func seatMap(_ context: SeatMapContext) async throws -> SeatMapResponse {
        guard var comps = URLComponents(string: "\(base)/seatmap/\(context.cartId)") else { throw SeatMapError.network }
        comps.queryItems = [
            URLQueryItem(name: "solutionId", value: context.solutionId),
            URLQueryItem(name: "nodeId", value: context.nodeId)
        ]
        guard let url = comps.url else { throw SeatMapError.network }
        let data = try await send(request(url))
        guard let map = try? JSONDecoder().decode(SeatMapResponse.self, from: data) else { throw SeatMapError.network }
        return map
    }

    // MARK: - Passi

    private static func search(trainNumber: String, fromId: Int, toId: Int, at date: Date) async throws -> SeatMapContext {
        guard let url = URL(string: "\(base)/ticket/solutions") else { throw SeatMapError.network }
        let body: [String: Any] = [
            "departureLocationId": fromId,
            "arrivalLocationId": toId,
            "departureTime": timeFormatter.string(from: date),
            "returnDepartureTime": NSNull(),
            "adults": 1,
            "children": 0,
            "criteria": [
                "frecceOnly": false, "regionalOnly": false, "intercityOnly": false,
                "tourismOnly": false, "noChanges": true,
                "order": "DEPARTURE_DATE", "offset": 0, "limit": 15
            ],
            "advancedSearchRequest": [
                "bestFare": false, "bikeFilter": false,
                "forwardDiscountCodes": [], "returnDiscountCodes": []
            ]
        ]
        var req = request(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(req)
        guard let response = try? JSONDecoder().decode(SeatSearchResponse.self, from: data),
              let cartId = response.cartId else { throw SeatMapError.network }

        // Soluzione diretta con esattamente il nostro treno.
        guard let match = (response.solutions ?? []).first(where: { sol in
            let trains = sol.solution?.trains ?? []
            return trains.count == 1 && trains.first?.name == trainNumber
        }), let info = match.solution, let solutionId = info.id,
              let nodeId = info.nodes?.first?.id else {
            throw SeatMapError.trainNotFound
        }

        let status = info.status ?? ""
        guard status == "SALEABLE" else { throw SeatMapError.notSaleable(status) }
        guard match.canShowSeatMap == true else { throw SeatMapError.noSeatMap }

        let grid = match.grids?.first
        // Tutte le classi: quelle esaurite restano senza offerKeys (nessuna mappa).
        let classes: [SeatClass] = (grid?.services ?? []).compactMap { service in
            guard let id = service.id else { return nil }
            let offer = (service.offers ?? []).first {
                $0.status == "SALEABLE" && !($0.offerKeys ?? []).isEmpty
            }
            return SeatClass(id: id,
                             name: (service.name ?? "Classe").capitalized,
                             minPrice: offer?.price?.amount,
                             offerKeys: offer?.offerKeys ?? [],
                             travellerIds: (offer?.travellers ?? []).compactMap(\.id))
        }

        return SeatMapContext(cartId: cartId, solutionId: solutionId, nodeId: nodeId,
                              classes: classes, defaultClassId: grid?.selectedServiceId)
    }

    /// Cambia l'offerta selezionata nel carrello (nessun acquisto): la mappa
    /// successiva mostra le carrozze della nuova classe.
    private static func selectClass(_ seatClass: SeatClass, context: SeatMapContext) async throws {
        guard let url = URL(string: "\(base)/grid/\(context.cartId)/update") else { throw SeatMapError.network }
        let body: [String: Any] = [
            "solutionId": context.solutionId,
            "upselling": false,
            "offeredServicesUpdate": [[
                "offerKeys": seatClass.offerKeys,
                "solutionId": context.solutionId,
                "travellers": seatClass.travellerIds.map { ["id": $0] }
            ]]
        ]
        var req = request(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(req)
    }

    // MARK: - ID stazioni

    /// ID lefrecce risolto per nome (autocomplete lefrecce + somiglianza dei nomi).
    static func resolvedId(for stop: TrainStop) async -> Int? {
        let name = searchableName(stop.stationName)
        let locations = await BigliettiService.searchStations(name)
        let target = Set(normalizedStationName(name).split(separator: " "))
        guard let best = locations.max(by: { score($0, target) < score($1, target) }),
              score(best, target) > 0 else { return nil }
        return best.id
    }

    /// "S01700" -> 830001700 (gli ID lefrecce sono 8300 + codice ViaggiaTreno).
    static func lefrecceId(fromViaggiaTreno code: String) -> Int? {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        return 830_000_000 + n
    }

    /// "BOLOGNA C.LE/AV" -> "Bologna Centrale" (nomi ViaggiaTreno abbreviati).
    private static func searchableName(_ name: String) -> String {
        var s = name.uppercased()
        s = s.replacingOccurrences(of: "C.LE", with: "CENTRALE")
        s = s.replacingOccurrences(of: "/AV", with: "")
        s = s.replacingOccurrences(of: "S.M.N.", with: "SANTA MARIA NOVELLA")
        return s.capitalized
    }

    private static func score(_ location: TrenitaliaLocation, _ target: Set<Substring>) -> Int {
        let tokens = Set(normalizedStationName(location.label).split(separator: " "))
        let multistation = location.label.localizedCaseInsensitiveContains("Tutte")
        return tokens.intersection(target).count * 2 - (multistation ? 1 : 0)
    }

    // MARK: - HTTP

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.000"
        return f
    }()

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SeatMapError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 400/404: stazione non valida per lefrecce, si prova il candidato
            // successivo. Il resto (5xx, 429, anti-bot) è un errore di rete.
            throw (status == 400 || status == 404) ? SeatMapError.trainNotFound : SeatMapError.network
        }
        return data
    }
}
