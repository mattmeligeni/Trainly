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
}

enum TrenordTicketService {

    private static let base = "https://cloud.mp.trenord.it/hafas/v2"

    /// Prima pagina: risolve i nomi (dal nome scelto sul catalogo Trenitalia) e
    /// cerca a partire dall'orario indicato. `nil` se una delle due stazioni non
    /// è servita da Trenord.
    static func firstPage(originName: String, destName: String,
                          date: Date, fromTime: String) async -> TrenordSearchResult? {
        let store = TrenordStationsStore.shared
        guard let origin = store.resolve(originName),
              let destination = store.resolve(destName) else { return nil }

        let (solutions, last) = await page(trenordOrigin: origin, trenordDestination: destination,
                                           date: date, fromTime: fromTime)
        return TrenordSearchResult(trenordOrigin: origin, trenordDestination: destination,
                                   date: date, solutions: solutions, lastDepTime: last)
    }

    /// Una pagina di soluzioni. Ritorna le soluzioni e l'orario di partenza
    /// dell'ultima (per calcolare l'inizio della pagina successiva).
    static func page(trenordOrigin: String, trenordDestination: String,
                     date: Date, fromTime: String) async -> (solutions: [TicketSolution], lastDepTime: String?) {
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
        guard let url = comps?.url else { return ([], nil) }

        let request = TrenordTicketAPI.request(url: url)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TrenordSolutionsResponse.self, from: data) else {
            return ([], nil)
        }

        let raw = decoded.solutions ?? []
        let solutions = raw.map { TicketSolution(trenordSolution: $0, originName: trenordOrigin, destName: trenordDestination) }
        let lastDep = raw.compactMap { $0.dep_time }.last.map(TrenordTime.hhmm)
        return (solutions, lastDep)
    }
}
