//
//  BigliettiService.swift
//  Trainly
//
//  Ricerca biglietti Trenitalia (lefrecce BFF). Nessuna autenticazione.
//

import Foundation

enum BigliettiError: Error {
    case invalidURL
    case invalidResponse
    case decodingFailed(Error)
}

enum BigliettiService {

    private static let base = "https://www.lefrecce.it/Channels.Website.BFF.WEB/website"

    /// Autocompletamento stazioni: restituisce nome + id numerico.
    static func searchStations(_ name: String) async -> [TrenitaliaLocation] {
        (try? await searchLocations(name)) ?? []
    }

    /// Come `searchStations`, ma un errore di rete resta un errore (non una lista vuota).
    static func searchLocations(_ name: String) async throws -> [TrenitaliaLocation] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, var comps = URLComponents(string: "\(base)/locations/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = comps.url else { throw BigliettiError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BigliettiError.invalidResponse }
        do {
            return try JSONDecoder().decode([TrenitaliaLocation].self, from: data)
        } catch {
            throw BigliettiError.decodingFailed(error)
        }
    }

    /// Sceglie fra i risultati lefrecce la stazione con lo stesso nome (uno dei
    /// `names`, es. testo e valore del cruscotto). Senza corrispondenza accetta
    /// solo un risultato unico: mai il "primo a caso".
    static func bestMatch(_ locations: [TrenitaliaLocation], for names: [String]) -> TrenitaliaLocation? {
        let exact = Set(names.map(normalizedStationName))
        if let hit = locations.first(where: { exact.contains(normalizedStationName($0.label)) }) { return hit }

        // Nomi abbreviati diversamente ("San"/"S."): stessa chiave e stesso tipo
        // (una stazione "Tutte le stazioni" non vale per la stazione singola).
        for name in names {
            let key = stationMatchKey(name)
            let multi = isMultistationName(name)
            if let hit = locations.first(where: {
                stationMatchKey($0.label) == key && isMultistationName($0.label) == multi
            }) { return hit }
        }
        return locations.count == 1 ? locations.first : nil
    }

    // Il BFF restituisce al massimo 10 soluzioni per chiamata, qualunque sia
    // `limit`: l'offset successivo è il numero di soluzioni già ricevute.
    private static let pageSize = 10
    private static let maxPages = 12

    /// Soluzioni di tutta la giornata a partire dall'orario scelto, come per Italo
    /// (che restituisce già l'intera giornata): così le liste dei due vettori sono
    /// confrontabili e l'ordinamento per prezzo non mescola fasce orarie diverse.
    /// `complete` è falso se una pagina successiva alla prima non è arrivata.
    static func searchDay(fromId: Int, toId: Int, date: Date,
                          adults: Int, children: Int,
                          frecceOnly: Bool = false,
                          regionalOnly: Bool = false,
                          intercityOnly: Bool = false) async throws -> (solutions: [TicketSolution], complete: Bool) {
        let requestedDay = dayString(date)
        var collected: [TicketSolution] = []
        var seen = Set<String>()
        var offset = 0

        for pageIndex in 0..<maxPages {
            let raw: [RawSolution]
            do {
                raw = try await page(fromId: fromId, toId: toId, date: date,
                                     adults: adults, children: children,
                                     frecceOnly: frecceOnly, regionalOnly: regionalOnly,
                                     intercityOnly: intercityOnly, offset: offset)
            } catch {
                // Prima pagina: errore vero. Dopo: teniamo quanto già caricato.
                if pageIndex == 0 || error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                return (collected, false)
            }

            // Scarta le soluzioni riferite al giorno successivo (lefrecce le aggiunge
            // quando non ci sono più treni in giornata): confrontiamo la data di
            // partenza col giorno richiesto, in modo indipendente dalla lingua.
            let sameDay = raw.filter { ($0.solution?.departureTime?.prefix(10)).map(String.init) == requestedDay }
            for sol in sameDay.map(TicketSolution.init(raw:)) where seen.insert(sol.id).inserted {
                var sol = sol
                sol.passengers = adults + children
                collected.append(sol)
            }

            // Fine giornata: pagina corta o soluzioni già del giorno dopo.
            if raw.count < pageSize || sameDay.count < raw.count { return (collected, true) }
            offset += raw.count
        }
        return (collected, true)
    }

    /// Ricerca soluzioni tra due stazioni (per id): una pagina, in ordine di partenza.
    private static func page(fromId: Int, toId: Int, date: Date,
                             adults: Int, children: Int,
                             frecceOnly: Bool, regionalOnly: Bool, intercityOnly: Bool,
                             offset: Int) async throws -> [RawSolution] {
        guard let url = URL(string: "\(base)/ticket/solutions") else { throw BigliettiError.invalidURL }

        // Orario della richiesta nel fuso italiano, qualunque sia quello del telefono.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TicketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.000"

        let body: [String: Any] = [
            "departureLocationId": fromId,
            "arrivalLocationId": toId,
            "departureTime": formatter.string(from: date),
            "returnDepartureTime": NSNull(),
            "adults": adults,
            "children": children,
            "criteria": [
                "frecceOnly": frecceOnly,
                "regionalOnly": regionalOnly,
                "intercityOnly": intercityOnly,
                "tourismOnly": false,
                "noChanges": false,
                "order": "DEPARTURE_DATE",
                "offset": offset,
                "limit": pageSize
            ],
            "advancedSearchRequest": [
                "bestFare": false,
                "bikeFilter": false,
                "forwardDiscountCodes": [],
                "returnDiscountCodes": []
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BigliettiError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(SolutionsResponse.self, from: data).solutions ?? []
        } catch {
            throw BigliettiError.decodingFailed(error)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "Europe/Rome")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.string(from: date)
    }
}
