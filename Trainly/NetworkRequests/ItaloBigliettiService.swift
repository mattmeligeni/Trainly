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
    // Italo rifiuta le versioni client vecchie («your app is obsolete», codice
    // 1130): a novembre 2026 serve almeno 5.1.0 (4.5.2 non passa più). Si provano
    // in ordine, così un nuovo innalzamento della soglia non rompe la ricerca.
    private static let clientVersions = ["5.1.0", "6.0.0", "9.9.9"]

    private static func loginBody(version: String) -> [String: Any] {
        [
            "Login": [
                "Username": "WWW_Anonymous",
                "Password": "F3hoM!n0$!ZE",
                "Domain": "WWW",
                "VersionNumber": version
            ],
            "SourceSystem": 2
        ]
    }

    // MARK: - Ricerca di alto livello

    /// Cerca i treni Italo tra due stazioni (per nome, risolto sul catalogo Italo).
    /// Restituisce solo le soluzioni vendibili in partenza dall'orario scelto in poi.
    /// Lancia `TicketSearchError.notServed` se Italo non ferma in una delle due
    /// stazioni, un errore di rete altrimenti: mai una lista vuota "di comodo".
    static func search(originName: String, destName: String, date: Date,
                       adults: Int, children: Int) async throws -> [TicketSolution] {
        let stations = try await catalog()
        let originCode = try resolveCode(originName, in: stations)
        let destCode = try resolveCode(destName, in: stations)
        guard let token = await login() else { throw TicketSearchError.server }
        let response = try await trains(token: token, origin: originCode, destination: destCode,
                                         date: date, adults: adults, children: children)

        // Codice -> nome, per le stazioni di cambio.
        var names: [String: String] = [:]
        for st in stations { if let code = st.stationCode, let name = st.name { names[code] = name } }

        var solutions: [TicketSolution] = []
        for market in response.JourneyDateMarkets ?? [] {
            for journey in market.Journeys ?? [] {
                // Una journey è una soluzione: più segmenti = cambi.
                let segments = journey.Segments ?? []
                guard !segments.isEmpty,
                      segments.allSatisfy({ !($0.Fares ?? []).isEmpty }) else { continue }
                // Italo restituisce tutta la giornata: teniamo dall'orario scelto.
                if let std = TicketSolution.italoDeparture(of: segments[0]), std < date { continue }
                solutions.append(TicketSolution(italoJourney: segments, originName: originName,
                                                destName: destName, stationNames: names,
                                                adults: adults, children: children))
            }
        }
        return solutions.sorted { $0.departure < $1.departure }
    }

    // MARK: - Stazioni

    // Catalogo Italo completo (meno di 100 stazioni): scaricato una volta e tenuto
    // in memoria, così la risoluzione è locale e non dipende dalla ricerca per testo.
    private static var cachedCatalog: (stations: [ItaloStation], date: Date)?

    private static func catalog() async throws -> [ItaloStation] {
        if let cached = cachedCatalog, Date().timeIntervalSince(cached.date) < 6 * 3600 {
            return cached.stations
        }
        guard var comps = URLComponents(string: stationsURL) else { throw TicketSearchError.server }
        comps.queryItems = [
            URLQueryItem(name: "ps", value: "500"),
            URLQueryItem(name: "culture", value: "it-IT"),
            URLQueryItem(name: "onlyitalo", value: "true")
        ]
        guard let url = comps.url else { throw TicketSearchError.server }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ItaloStationsResponse.self, from: data) else {
            throw TicketSearchError.server
        }
        // Solo stazioni ferroviarie Italo (le fermate bus hanno classe "B").
        let stations = (decoded.stations ?? []).filter { $0.isItaloStation == true && $0.stationClass != "B" }
        guard !stations.isEmpty else { throw TicketSearchError.server }
        cachedCatalog = (stations, Date())
        return stations
    }

    // Stazioni Italo con un nome diverso da quello Trenitalia (chiavi di
    // `stationMatchKey`). Elenco esplicito: una regola "per prefisso" farebbe
    // diventare "Salerno" anche Salerno Irno o "Ferrara" Ferrara-Cona.
    private static let italoNameAliases: [String: String] = [
        "AGROPOLI CASTELLABATE": "AGROPOLI",
        "BOLZANO BOZEN": "BOLZANO",
        "DESENZANO DEL GARDA SIRMIONE": "DESENZANO",
        "PESCHIERA DEL GARDA": "PESCHIERA",
        "RHO FIERA MILANO": "MILANO RHO FIERA",
        "S DONA DI PIAVE JESOLO": "S DONA JESOLO",
        "SCALEA S DOMENICA TALAO": "SCALEA",
        "VALLO DELLA LUCANIA CASTELNUOVO": "VALLO DELLA LUCANIA",
        "VIBO VALENTIA PIZZO": "VIBO PIZZO"
    ]

    /// Codice Italo della stazione con lo stesso nome (confronto stretto).
    /// "Città ( Tutte Le Stazioni )" diventa la stazione cumulativa Italo
    /// ("Milano (Tutte)") o l'unica stazione Italo di quella città.
    static func resolveCode(_ name: String, in stations: [ItaloStation]) throws -> String {
        let city = stationNameWithoutParentheses(name)
        let found: ItaloStation?
        if isMultistationName(name) {
            let cityKey = stationMatchKey(city)
            if let mac = stations.first(where: { $0.isMAC == true && stationMatchKey($0.name ?? "") == cityKey }) {
                found = mac
            } else {
                let inCity = stations.filter { st in
                    let key = stationMatchKey(st.name ?? "")
                    return key == cityKey || key.hasPrefix(cityKey + " ")
                }
                guard inCity.count <= 1 else {
                    throw TicketSearchError.notServed("Italo ha più stazioni a \(city): scegline una specifica.")
                }
                found = inCity.first
            }
        } else {
            let key = stationMatchKey(name)
            let target = italoNameAliases[key] ?? key
            found = stations.first { $0.isMAC != true && stationMatchKey($0.name ?? "") == target }
        }
        guard let code = found?.stationCode else {
            throw TicketSearchError.notServed("Italo non ferma a \(city).")
        }
        return code
    }

    // MARK: - Passi

    static func login() async -> String? {
        guard let url = URL(string: loginURL) else { return nil }
        for version in clientVersions {
            guard let body = try? JSONSerialization.data(withJSONObject: loginBody(version: version)) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let signature = (try? JSONDecoder().decode(ItaloLoginResponse.self, from: data))?.Signature {
                return signature
            }
            // Solo «versione obsoleta» giustifica un altro tentativo.
            guard (try? JSONDecoder().decode(ItaloErrorResponse.self, from: data))?.Code == 1130 else { return nil }
        }
        return nil
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

    private static func trains(token: String, origin: String, destination: String,
                               date: Date, adults: Int, children: Int) async throws -> ItaloTrainsResponse {
        guard let url = URL(string: trainsURL) else { throw TicketSearchError.server }

        // Giornata intera nel fuso italiano, non in quello del telefono.
        let cal = TicketClock.calendar
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
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ItaloTrainsResponse.self, from: data) else {
            throw TicketSearchError.server
        }
        return decoded
    }
}
