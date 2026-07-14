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

struct CruscottoEntry: Codable, Identifiable, Hashable {
    let value: String
    let text: String

    var id: String { text }
    // I campi isF/FB/FA/isE del JSON originale vengono ignorati.
}

final class TrenitaliaStationsStore: ObservableObject {
    static let shared = TrenitaliaStationsStore()

    @Published private(set) var stations: [CruscottoEntry] = []

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
        if fetched != stations {
            await MainActor.run { stations = fetched }
            if let data = try? JSONEncoder().encode(fetched) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastFetchKey)
    }

    /// Suggerimenti locali istantanei (prefix match prima).
    func suggest(_ query: String, limit: Int = 12) -> [CruscottoEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        let matches = stations.filter { $0.text.lowercased().contains(q) }
        return Array(matches.sorted { a, b in
            let ap = a.text.lowercased().hasPrefix(q)
            let bp = b.text.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a.text < b.text
        }.prefix(limit))
    }

    // MARK: - Persistenza

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([CruscottoEntry].self, from: data) else { return }
        stations = decoded
    }

    private func download() async -> [CruscottoEntry]? {
        var request = URLRequest(url: remoteURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        // Il JSON è codificato ISO-8859-1: riconvertiamo in UTF-8 prima del decode.
        let jsonData: Data
        if let latin = String(data: data, encoding: .isoLatin1) {
            jsonData = Data(latin.utf8)
        } else {
            jsonData = data
        }
        return try? JSONDecoder().decode([CruscottoEntry].self, from: jsonData)
    }
}
