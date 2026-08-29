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
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, var comps = URLComponents(string: "\(base)/locations/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = comps.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let locations = try? JSONDecoder().decode([TrenitaliaLocation].self, from: data) else {
            return []
        }
        return locations
    }

    /// Ricerca soluzioni tra due stazioni (per id).
    static func searchSolutions(fromId: Int, toId: Int, date: Date,
                                adults: Int, children: Int,
                                frecceOnly: Bool = false,
                                regionalOnly: Bool = false,
                                intercityOnly: Bool = false) async throws -> [TicketSolution] {
        guard let url = URL(string: "\(base)/ticket/solutions") else { throw BigliettiError.invalidURL }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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
                "offset": 0,
                "limit": 15
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BigliettiError.invalidResponse
        }
        do {
            let decoded = try JSONDecoder().decode(SolutionsResponse.self, from: data)
            // Scarta le soluzioni riferite al giorno successivo (lefrecce le aggiunge
            // quando non ci sono più treni in giornata): confrontiamo la data di
            // partenza col giorno richiesto, in modo indipendente dalla lingua.
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = TimeZone(identifier: "Europe/Rome")
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let requestedDay = dayFormatter.string(from: date)

            return (decoded.solutions ?? [])
                .filter { ($0.solution?.departureTime?.prefix(10)).map(String.init) == requestedDay }
                .map(TicketSolution.init(raw:))
        } catch {
            throw BigliettiError.decodingFailed(error)
        }
    }
}
