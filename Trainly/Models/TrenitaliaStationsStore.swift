//
//  TrenitaliaStationsStore.swift
//  Trainly
//
//  Catalogo stazioni Trenitalia (cruscotto-stations.json) con persistenza su
//  disco: scaricato una volta e ricontrollato al massimo una volta a settimana,
//  salvando solo se il contenuto è cambiato. Serve per suggerimenti istantanei.
//

import Foundation
internal import Combine

// `nonisolated`: decodificato fuori dal main actor (il catalogo è grande).
nonisolated struct CruscottoEntry: Codable, Identifiable, Hashable, Sendable {
    let value: String
    let text: String

    var id: String { text }
    // I campi isF/FB/FA/isE del JSON originale vengono ignorati.
}

// Main actor esplicito: `stations` e `normalized` cambiano sempre insieme e
// solo qui; le viste lo osservano con @ObservedObject.
@MainActor
final class TrenitaliaStationsStore: ObservableObject {
    static let shared = TrenitaliaStationsStore()

    @Published private(set) var stations: [CruscottoEntry] = []
    /// Nomi normalizzati (stesso ordine di `stations`): "forli" trova "Forlì".
    private var normalized: [String] = []

    private let remoteURL = URL(string: "https://www.trenitalia.com/content/trenitalia/it.cruscotto-stations.json")!
    private let cacheURL: URL
    private let lastFetchKey = "cruscottoLastFetch"
    private let maxAge: TimeInterval = 7 * 86_400   // una settimana

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = caches.appendingPathComponent("cruscotto-stations.json")
        loadFromDisk()
    }

    /// Ricontrolla solo se non abbiamo dati o è passata più di una settimana.
    func refreshIfNeeded() async {
        let last = UserDefaults.standard.object(forKey: lastFetchKey) as? Date
        if !stations.isEmpty, let last, Date().timeIntervalSince(last) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard let fetched = await download() else { return }
        // Salva su disco solo se il contenuto è effettivamente cambiato.
        if fetched.entries != stations {
            apply(fetched)
            if let data = try? JSONEncoder().encode(fetched.entries) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastFetchKey)
    }

    /// Suggerimenti locali istantanei (prefix match prima). Il confronto è sui
    /// nomi normalizzati: senza accenti, maiuscole e punteggiatura.
    func suggest(_ query: String, limit: Int = 12) -> [CruscottoEntry] {
        let q = normalizedStationName(query)
        guard q.count >= 2 else { return [] }
        let matches = zip(stations, normalized).filter { $0.1.contains(q) }
        return matches.sorted { a, b in
            let ap = a.1.hasPrefix(q)
            let bp = b.1.hasPrefix(q)
            if ap != bp { return ap }
            return a.0.text < b.0.text
        }.prefix(limit).map(\.0)
    }

    private func apply(_ catalog: (entries: [CruscottoEntry], normalized: [String])) {
        stations = catalog.entries
        normalized = catalog.normalized
    }

    // MARK: - Persistenza

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([CruscottoEntry].self, from: data) else { return }
        apply((decoded, decoded.map { normalizedStationName($0.text) }))
    }

    private func download() async -> (entries: [CruscottoEntry], normalized: [String])? {
        var request = URLRequest(url: remoteURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return await Self.decode(data)
    }

    /// `@concurrent`: conversione e decodifica di ~4000 stazioni fuori dal main thread.
    @concurrent
    private nonisolated static func decode(_ data: Data) async -> (entries: [CruscottoEntry], normalized: [String])? {
        // Il JSON è codificato ISO-8859-1: riconvertiamo in UTF-8 prima del decode.
        let jsonData: Data
        if let latin = String(data: data, encoding: .isoLatin1) {
            jsonData = Data(latin.utf8)
        } else {
            jsonData = data
        }
        guard let entries = try? JSONDecoder().decode([CruscottoEntry].self, from: jsonData) else { return nil }
        return (entries, entries.map { normalizedStationName($0.text) })
    }
}
