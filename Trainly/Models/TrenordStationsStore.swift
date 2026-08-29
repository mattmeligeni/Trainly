//
//  TrenordStationsStore.swift
//  Trainly
//
//  Catalogo stazioni Trenord (cloud.mp.trenord.it/v2/stazioni_v2) con persistenza
//  su disco: scaricato una volta e ricontrollato al massimo una volta a settimana,
//  salvando solo se il contenuto è cambiato. Serve a risolvere il nome esatto della
//  stazione richiesto dalla ricerca soluzioni hafas partendo dal nome scelto nel
//  catalogo Trenitalia (più completo).
//

import Foundation
internal import Combine

/// Costanti condivise dell'API biglietti Trenord (usate da store e service).
enum TrenordTicketAPI {
    static let secret = "1ce375f6cf06d6dec151a59a486aee2ac577f9144b5cc35954c4535e77290ecd67cec7a733be30e6de7953b02c3c24f664f62dde9aa1d2f21d15338d42a4b707844e7d19ecc029943c37ac9f26b6977a159c707041bb703d4954a4a6914bcdd1cdd8cd474e60f72d317f5185068220dccb253a88e4aa9a63a6676446ed2ed33bb68d8bf62ebac49d19ac5a6011424b763af1f2e05b706ff18ca6d58d06c4cc9776fdb03381e196f6ea0a30af53220cab2adce87e25c8c8630264820015f198a02be33dfd1b7709a9b88ec0f5c56411393eb3edaf36637d19df26b39ae7e7e0896ef114c0868798f0f6ef7be8fa4f5454638c3373748a47de2fc1f75a447f384c"

    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(secret, forHTTPHeaderField: "secret")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }
}

struct TrenordStationEntry: Codable, Hashable {
    let name: String            // NomeGeoStazioni: esattamente il valore atteso dall'API hafas
}

/// Risposta grezza del catalogo (solo il campo che ci serve).
private struct RawTrenordStation: Codable {
    let NomeGeoStazioni: String?
}

final class TrenordStationsStore: ObservableObject {
    static let shared = TrenordStationsStore()

    @Published private(set) var stations: [TrenordStationEntry] = []

    private let remoteURL = URL(string: "https://cloud.mp.trenord.it/v2/stazioni_v2/")!
    private let cacheURL: URL
    private let lastFetchKey = "trenordStationsLastFetch"
    private let maxAge: TimeInterval = 7 * 86_400   // una settimana

    /// Indice normalizzato -> nome esatto, per la risoluzione.
    private var index: [String: String] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = caches.appendingPathComponent("trenord-stations.json")
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
        if fetched != stations {
            await MainActor.run { self.stations = fetched }
            rebuildIndex(fetched)
            if let data = try? JSONEncoder().encode(fetched) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastFetchKey)
    }

    /// Nome esatto della stazione Trenord corrispondente al nome dato (di solito
    /// proveniente dal catalogo Trenitalia). `nil` se la stazione non è servita.
    func resolve(_ name: String) -> String? {
        index[normalizedStationName(name)]
    }

    /// Suggerimenti locali istantanei per il picker Trenord (prefix match prima).
    func suggest(_ query: String, limit: Int = 12) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        let matches = stations.map(\.name).filter { $0.lowercased().contains(q) }
        return Array(matches.sorted { a, b in
            let ap = a.lowercased().hasPrefix(q)
            let bp = b.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a < b
        }.prefix(limit))
    }

    // MARK: - Persistenza

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([TrenordStationEntry].self, from: data) else { return }
        stations = decoded
        rebuildIndex(decoded)
    }

    private func rebuildIndex(_ entries: [TrenordStationEntry]) {
        var map: [String: String] = [:]
        for e in entries { map[normalizedStationName(e.name)] = e.name }
        index = map
    }

    private func download() async -> [TrenordStationEntry]? {
        let request = TrenordTicketAPI.request(url: remoteURL)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let raw = try? JSONDecoder().decode([RawTrenordStation].self, from: data) else { return nil }

        let entries = raw.compactMap { r -> TrenordStationEntry? in
            guard let n = r.NomeGeoStazioni, !n.isEmpty else { return nil }
            return TrenordStationEntry(name: n)
        }
        return entries.isEmpty ? nil : entries
    }
}
