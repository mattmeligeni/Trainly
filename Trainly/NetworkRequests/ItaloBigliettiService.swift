//
//  ItaloBigliettiService.swift
//  Trainly
//
//  Ricerca biglietti Italo: login anonimo -> risoluzione codici stazione ->
//  GetAvailableTrains. Nessun dato personale, nessun acquisto.
//

import Foundation

enum ItaloTicketService {

    private static let base = "https://big.ntvspa.it/BIG/v7/Rest"
    private static let loginURL = "\(base)/SessionManager.svc/Login"
    private static let trainsURL = "\(base)/BookingManager.svc/GetAvailableTrains"
    private static let stationsURL = "https://api-biglietti.italotreno.com/api/v1/stations"

    // Credenziali anonime pubbliche usate dal sito Italo (utente ospite).
    private static let loginBody: [String: Any] = [
        "Login": [
            "Username": "WWW_Anonymous",
            "Password": "F3hoM!n0$!ZE",
            "Domain": "WWW",
            "VersionNumber": "4.5.2"
        ],
        "SourceSystem": 2
    ]

    // MARK: - Ricerca di alto livello

    /// Cerca i treni Italo tra due stazioni (per nome, risolto sul catalogo Italo).
    /// Restituisce solo i segmenti vendibili in partenza dall'orario scelto in poi.
    static func search(originName: String, destName: String, date: Date,
                       adults: Int, children: Int) async -> [TicketSolution] {
        guard let token = await login(),
              let originCode = await resolveCode(originName),
              let destCode = await resolveCode(destName),
              let response = await trains(token: token, origin: originCode, destination: destCode,
                                          date: date, adults: adults, children: children)
        else { return [] }

        var solutions: [TicketSolution] = []
        for market in response.JourneyDateMarkets ?? [] {
            for journey in market.Journeys ?? [] {
                for segment in journey.Segments ?? [] {
                    guard let fares = segment.Fares, !fares.isEmpty else { continue }
                    // Italo restituisce tutta la giornata: teniamo dall'orario scelto.
                    if let std = TicketSolution.italoDeparture(of: segment), std < date { continue }
                    solutions.append(TicketSolution(italoSegment: segment, originName: originName, destName: destName))
                }
            }
        }
        return solutions.sorted { $0.departure < $1.departure }
    }

    // MARK: - Passi

    static func login() async -> String? {
        guard let url = URL(string: loginURL),
              let body = try? JSONSerialization.data(withJSONObject: loginBody) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ItaloLoginResponse.self, from: data) else { return nil }
        return decoded.Signature
    }

    /// Cerca le stazioni Italo per nome (autocomplete ufficiale).
    static func searchStations(_ query: String) async -> [ItaloStation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, var comps = URLComponents(string: stationsURL) else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "sn", value: q),
            URLQueryItem(name: "ps", value: "10"),
            URLQueryItem(name: "culture", value: "it-IT"),
            URLQueryItem(name: "onlyitalo", value: "true")
        ]
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ItaloStationsResponse.self, from: data) else { return [] }
        return (decoded.stations ?? []).filter { $0.isItaloStation == true }
    }

    /// Risolve il codice stazione Italo dal nome (match normalizzato, altrimenti
    /// il primo risultato utile).
    static func resolveCode(_ name: String) async -> String? {
        let results = await searchStations(name)
        guard !results.isEmpty else { return nil }
        let target = normalizedStationName(name)
        let exact = results.first { normalizedStationName($0.name ?? "") == target }
        return (exact ?? results.first)?.stationCode
    }

    private static func trains(token: String, origin: String, destination: String,
                               date: Date, adults: Int, children: Int) async -> ItaloTrainsResponse? {
        guard let url = URL(string: trainsURL) else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) ?? date
        let startMs = Int(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int(endOfDay.timeIntervalSince1970 * 1000)

        let body: [String: Any] = [
            "GetAvailableTrains": [
                "RoundTrip": false,
                "DepartureStation": origin,
                "ArrivalStation": destination,
                "IntervalStartDateTime": "/Date(\(startMs)+0000)/",
                "IntervalEndDateTime": "/Date(\(endMs)+0000)/",
                "AdultNumber": max(1, adults),
                "YoungNumber": 0,
                "ChildNumber": max(0, children),
                "InfantNumber": 0,
                "SeniorNumber": 0,
                "CurrencyCode": "EUR",
                "ShowFareBasisRestrictionRules": true,
                "ShowNestedSSR": true,
                "IsGuest": true,
                "OverrideIntervalTimeRestriction": true,
                "AvailabilityFilter": 1,
                "FareClassControl": 0
            ],
            "Signature": token,
            "SourceSystem": 2
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ItaloTrainsResponse.self, from: data)
    }
}
