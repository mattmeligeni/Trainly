
//
//  ScioperiService.swift
//  Trainly
//
//  Scioperi dal feed RSS del MIT, filtrati per settore "Ferroviario".
//

import Foundation
internal import Combine

// MARK: - Modelli

struct StrikeInfo: Codable, Identifiable {
    let id: String
    let dataInizio: String?
    let dataFine: String?
    let settore: String?
    let rilevanza: String?
    let regione: String?
    let provincia: String?
    let fieldA: String?      // valore della chiave "modalità" (spesso i sindacati)
    let fieldB: String?      // valore della chiave "Sindacati" (spesso la modalità)
    let categoria: String?

    init(rawTitle: String, rawDesc: String, guid: String) {
        func pairs(_ parts: [String]) -> [String: String] {
            var d: [String: String] = [:]
            for p in parts {
                guard let r = p.range(of: ":") else { continue }
                let k = p[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                let v = p[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { d[k] = v }
            }
            return d
        }
        let t = pairs(rawTitle.components(separatedBy: " - "))
        let d = pairs(rawDesc.components(separatedBy: "<br/>"))

        id = guid
        dataInizio = t["data inizio"] ?? d["data inizio"]
        dataFine = d["data fine"]
        settore = t["settore"] ?? d["settore"]
        rilevanza = t["rilevanza"] ?? d["rilevanza"]
        regione = t["regione"] ?? d["regione"]
        provincia = t["provincia"] ?? d["provincia"]
        fieldA = d["modalità"] ?? d["modalita"]
        fieldB = d["sindacati"]
        categoria = d["categoria interessata"]
    }

    /// Vero se un qualsiasi campo cita il settore ferroviario (RSS mal strutturato).
    var mentionsRailway: Bool {
        let blob = [settore, rilevanza, fieldA, fieldB, categoria]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return blob.contains("ferroviar") || blob.contains("rotaia")
    }
}

struct ScioperiFeed: Codable {
    let title: String
    let description: String
    let strikes: [StrikeInfo]
    let updatedAt: Date
}

// MARK: - Servizio

enum ScioperiError: Error { case invalidURL, invalidResponse }

enum ScioperiService {
    // HTTPS diretto: evita il redirect http->https dopo il quale URLSession
    // non decomprimeva il gzip. "Accept-Encoding: identity" forza XML in chiaro.
    private static let urlString = "https://scioperi.mit.gov.it/mit2/public/scioperi/rss"

    static func fetch() async throws -> ScioperiFeed {
        guard let url = URL(string: urlString) else { throw ScioperiError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScioperiError.invalidResponse
        }

        let parser = RSSParser()
        let parsed = try parser.parse(data)
        let strikes = parsed.items
            .map { StrikeInfo(rawTitle: $0.title, rawDesc: $0.desc, guid: $0.guid) }
            .filter { s in
                let settore = (s.settore ?? "").lowercased()
                // Ferroviario esatto (non "Appalti ferroviari") e Generale: sempre.
                if settore == "ferroviario" || settore == "generale" { return true }
                // Plurisettoriale: solo se un campo cita il ferroviario.
                if settore == "plurisettoriale" { return s.mentionsRailway }
                return false
            }

        return ScioperiFeed(title: parsed.channelTitle,
                            description: parsed.channelDesc,
                            strikes: strikes,
                            updatedAt: Date())
    }
}

// MARK: - Parser RSS

private final class RSSParser: NSObject, XMLParserDelegate {
    struct RawItem { var title = ""; var desc = ""; var guid = "" }
    struct Result { var channelTitle = ""; var channelDesc = ""; var items: [RawItem] = [] }

    private var result = Result()
    private var current: RawItem?
    private var buffer = ""

    func parse(_ data: Data) throws -> Result {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? ScioperiError.invalidResponse }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
        if el == "item" { current = RawItem() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil {
            switch el {
            case "title": current?.title = text
            case "description": current?.desc = text
            case "guid": current?.guid = text
            case "item": if let c = current { result.items.append(c) }; current = nil
            default: break
            }
        } else {
            // Livello canale: il primo title/description sono quelli del feed.
            if el == "title", result.channelTitle.isEmpty { result.channelTitle = text }
            if el == "description", result.channelDesc.isEmpty { result.channelDesc = text }
        }
        buffer = ""
    }
}

// MARK: - Store (cache in UserDefaults, refresh se più vecchio di 1 giorno)

@MainActor
final class ScioperiStore: ObservableObject {
    @Published private(set) var feed: ScioperiFeed?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let cacheKey = "scioperiFeedCache"
    private let maxAge: TimeInterval = 86_400   // 1 giorno

    init() { loadCache() }

    func refreshIfNeeded() async {
        if let feed, Date().timeIntervalSince(feed.updatedAt) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await ScioperiService.fetch()
            feed = fetched
            saveCache(fetched)
        } catch {
            if feed == nil { errorMessage = "Impossibile caricare gli scioperi." }
        }
        isLoading = false
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(ScioperiFeed.self, from: data) else { return }
        feed = cached
    }

    private func saveCache(_ feed: ScioperiFeed) {
        if let data = try? JSONEncoder().encode(feed) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
