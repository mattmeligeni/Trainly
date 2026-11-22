//
//  TrenordBigliettiService.swift
//  Trainly
//
//  Ricerca soluzioni Trenord (hafas/v2), paginata a 5 risultati per chiamata.
//  I nomi stazione vengono risolti sul catalogo Trenord (TrenordStationsStore).
//

import Foundation

/// Esito della prima pagina: include i nomi Trenord risolti, così la paginazione
/// ("Mostra successivi") può riusarli senza ripetere la risoluzione.
struct TrenordSearchResult {
    let trenordOrigin: String
    let trenordDestination: String
    let date: Date
    let solutions: [TicketSolution]
    let lastDepTime: String?
    var endOfDay = false
}

/// Una pagina hafas già filtrata sulla giornata richiesta.
struct TrenordPage {
    let solutions: [TicketSolution]
    let lastDepTime: String?
    /// La pagina arriva alla fine della giornata: niente "Mostra successivi".
    let endOfDay: Bool
}

enum TrenordTicketService {

    private static let base = "https://cloud.mp.trenord.it/hafas/v2"

    /// Prima pagina: risolve i nomi (dal nome scelto sul catalogo Trenitalia) e
    /// cerca a partire dall'orario indicato. Lancia `notServed` se una delle due
    /// stazioni non è servita da Trenord, un errore di rete altrimenti.
    static func firstPage(originName: String, destName: String,
                          date: Date, fromTime: String) async throws -> TrenordSearchResult {
        let store = TrenordStationsStore.shared
        // Primo avvio: il catalogo potrebbe non essere ancora arrivato.
        if store.stations.isEmpty { await store.refreshIfNeeded() }
        guard !store.stations.isEmpty else { throw TicketSearchError.server }
        guard let origin = store.resolve(originName) else {
            throw TicketSearchError.notServed("Trenord non serve \(originName).")
        }
        guard let destination = store.resolve(destName) else {
            throw TicketSearchError.notServed("Trenord non serve \(destName).")
        }

        let first = try await page(trenordOrigin: origin, trenordDestination: destination,
                                   date: date, fromTime: fromTime)
        return TrenordSearchResult(trenordOrigin: origin, trenordDestination: destination,
                                   date: date, solutions: first.solutions,
                                   lastDepTime: first.lastDepTime, endOfDay: first.endOfDay)
    }

    /// Una pagina di soluzioni. Ritorna le soluzioni e l'orario di partenza
    /// dell'ultima (per calcolare l'inizio della pagina successiva).
    static func page(trenordOrigin: String, trenordDestination: String,
                     date: Date, fromTime: String) async throws -> TrenordPage {
        let dateStr: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Europe/Rome")
            f.dateFormat = "yyyyMMdd"
            return f.string(from: date)
        }()

        var comps = URLComponents(string: base)
        comps?.queryItems = [
            URLQueryItem(name: "orig", value: trenordOrigin),
            URLQueryItem(name: "dest", value: trenordDestination),
            URLQueryItem(name: "departure_date", value: dateStr),
            URLQueryItem(name: "departure_hour", value: fromTime),
            URLQueryItem(name: "type", value: "0"),
            URLQueryItem(name: "live_data", value: "true"),
            URLQueryItem(name: "plus", value: "true"),
            URLQueryItem(name: "no_changes", value: "0"),
            URLQueryItem(name: "transfers", value: "1"),
            URLQueryItem(name: "language", value: "it"),
            URLQueryItem(name: "products", value: "all")
        ]
        guard let url = comps?.url else { throw TicketSearchError.server }

        var request = TrenordTicketAPI.request(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TrenordSolutionsResponse.self, from: data) else {
            throw TicketSearchError.server
        }

        let raw = decoded.solutions ?? []
        // Partenze ben prima dell'orario richiesto = treni del giorno dopo (hafas
        // prosegue oltre la mezzanotte): li scartiamo e chiudiamo la giornata.
        // Un'ora di margine per non scambiare un anticipo di hafas per un giro di giorno.
        let fromMinutes = TrenordTime.minutes(fromTime) ?? 0
        let sameDay = raw.filter { sol in
            guard let dep = TrenordTime.minutes(sol.dep_time) else { return true }
            return dep >= fromMinutes - 60
        }
        let solutions = sameDay.map { TicketSolution(trenordSolution: $0, originName: trenordOrigin, destName: trenordDestination) }
        let lastDep = sameDay.compactMap { $0.dep_time }.last.map(TrenordTime.hhmm)
        let endOfDay = raw.isEmpty || sameDay.count < raw.count
            || lastDep.flatMap(TrenordTime.nextMinute) == nil
        return TrenordPage(solutions: solutions, lastDepTime: lastDep, endOfDay: endOfDay)
    }
}
