
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

        // guid mancante: id stabile da titolo e descrizione (non `hashValue`,
        // che cambia a ogni avvio e romperebbe la cache).
        let trimmedGuid = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        id = trimmedGuid.isEmpty ? "strike-" + Self.stableHash(rawTitle + "|" + rawDesc) : trimmedGuid
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

    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// MARK: - Date, modalità e sindacati

extension StrikeInfo {
    /// Calendario italiano: le date del feed sono giorni a Roma, non nel fuso del telefono.
    static let romeCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "it_IT")
        cal.timeZone = TimeZone(identifier: "Europe/Rome") ?? .current
        return cal
    }()

    /// Inizio del giorno (Roma) da "dd/MM/yyyy", anche se seguito da un orario.
    static func parseDay(_ raw: String?) -> Date? {
        guard let raw,
              let regex = try? NSRegularExpression(pattern: "(\\d{1,2})/(\\d{1,2})/(\\d{4})"),
              let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let dr = Range(m.range(at: 1), in: raw), let mr = Range(m.range(at: 2), in: raw),
              let yr = Range(m.range(at: 3), in: raw),
              let d = Int(raw[dr]), let mo = Int(raw[mr]), let y = Int(raw[yr]) else { return nil }
        return romeCalendar.date(from: DateComponents(year: y, month: mo, day: d))
    }

    var startDay: Date? { Self.parseDay(dataInizio) ?? Self.parseDay(dataFine) }
    var endDay: Date? { Self.parseDay(dataFine) ?? Self.parseDay(dataInizio) }

    /// I due campi a volte sono invertiti nel feed: la modalità descrive orari
    /// e durata, i sindacati sono sigle. Di norma la chiave "modalità" contiene
    /// i sindacati (vedi `fieldA`).
    private static func looksLikeModality(_ s: String) -> Bool {
        let l = s.lowercased()
        let hints = ["dalle", "giornata", "turno", "minuti", "sciopero"]
        return l.rangeOfCharacter(from: .decimalDigits) != nil || hints.contains { l.contains($0) }
    }

    private var orderedFields: (modality: String?, unions: String?) {
        let a = fieldA.flatMap { $0.isEmpty ? nil : $0 }
        let b = fieldB.flatMap { $0.isEmpty ? nil : $0 }
        if let a, Self.looksLikeModality(a), !(b.map { Self.looksLikeModality($0) } ?? false) {
            return (a, b)
        }
        return (b, a)
    }

    var modality: String? { orderedFields.modality }
    var unions: String? { orderedFields.unions }
}

/// Raggruppamento per l'elenco: in corso/oggi, prossimi 7 giorni, più avanti.
enum StrikeSection: CaseIterable {
    case today, nextWeek, later, undated

    var title: String {
        switch self {
        case .today: return "In corso / oggi"
        case .nextWeek: return "Prossimi 7 giorni"
        case .later: return "Più avanti"
        case .undated: return "Data non indicata"
        }
    }
}

extension ScioperiFeed {
    /// Scioperi non ancora finiti, ordinati per inizio e divisi in sezioni.
    /// Calcolato all'apertura: la cache resta valida anche il giorno dopo.
    func sections(now: Date = Date()) -> [(section: StrikeSection, strikes: [StrikeInfo])] {
        let cal = StrikeInfo.romeCalendar
        let today = cal.startOfDay(for: now)
        guard let weekEnd = cal.date(byAdding: .day, value: 7, to: today) else { return [] }

        var groups: [StrikeSection: [StrikeInfo]] = [:]
        for s in strikes {
            guard let start = s.startDay, let end = s.endDay else {
                groups[.undated, default: []].append(s)
                continue
            }
            if end < today { continue }   // già finito
            let section: StrikeSection = start <= today ? .today : (start <= weekEnd ? .nextWeek : .later)
            groups[section, default: []].append(s)
        }
        return StrikeSection.allCases.compactMap { section in
            guard let list = groups[section], !list.isEmpty else { return nil }
            let sorted = list.sorted {
                ($0.startDay ?? .distantFuture, $0.endDay ?? .distantFuture)
                    < ($1.startDay ?? .distantFuture, $1.endDay ?? .distantFuture)
            }
            return (section, sorted)
        }
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
        var seen: Set<String> = []
        let strikes = parsed.items
            .map { StrikeInfo(rawTitle: $0.title, rawDesc: $0.desc, guid: $0.guid) }
            .filter { seen.insert($0.id).inserted }   // id duplicati romperebbero il ForEach
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

// MARK: - Store (cache in UserDefaults, refresh se più vecchio di 2 ore)

@MainActor
final class ScioperiStore: ObservableObject {
    @Published private(set) var feed: ScioperiFeed?
    @Published private(set) var isLoading = false
    /// Errore dell'ultimo refresh, anche se ci sono dati in cache da mostrare.
    @Published private(set) var errorMessage: String?

    private let cacheKey = "scioperiFeedCache"
    // 2 ore: gli scioperi vengono aggiunti o revocati anche a ridosso della data.
    private let maxAge: TimeInterval = 2 * 3600
    private var refreshTask: Task<Void, Never>?

    init() { loadCache() }

    func refreshIfNeeded() async {
        if let feed, Date().timeIntervalSince(feed.updatedAt) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        // .task, pull-to-refresh e Riprova condividono lo stesso download:
        // niente richieste parallele che si sovrascrivono.
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        do {
            let fetched = try await ScioperiService.fetch()
            feed = fetched
            errorMessage = nil
            saveCache(fetched)
        } catch {
            // I dati in cache restano; l'errore viene comunque segnalato.
            if let urlError = error as? URLError,
               [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(urlError.code) {
                errorMessage = "Nessuna connessione a Internet."
            } else {
                errorMessage = "Impossibile caricare gli scioperi."
            }
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
