//
//  InfomobilitaService.swift
//  Trainly
//
//  Scraping della pagina Infomobilità di Trenitalia.
//  I contenuti (anche quelli nelle sezioni collassate) sono nell'HTML.
//

import Foundation

// Modelli `nonisolated` e Sendable: il parsing gira fuori dal main thread.
nonisolated struct InfoLink: Identifiable, Sendable {
    var id: Int { number }     // stabile tra un ricaricamento e l'altro
    let number: Int            // riferimento "(1)", "(2)"… nel testo
    let label: String
    let url: URL?
    let trainRef: ExactTrenitaliaRef?  // link a una corsa esatta (origine+numero+data)
    let isGenericSearch: Bool          // link "cerca treno" generico -> tab Cerca
}

nonisolated struct InfoTag: Identifiable, Sendable {
    let id: String
    let label: String
    let highlighted: Bool   // "In evidenza" (tag blu) -> badge giallo
}

/// Gravità ricavata dal colore della left-bar del sito, con un nome testuale
/// per non affidarla al solo colore (VoiceOver, daltonici).
nonisolated enum InfoSeverity: Sendable {
    case disruption, notice, scheduled, info

    init(color: String?) {
        switch color {
        case "red": self = .disruption
        case "orange": self = .notice
        case "green": self = .scheduled
        default: self = .info
        }
    }

    var label: String {
        switch self {
        case .disruption: return "Disservizio"
        case .notice: return "Comunicazione"
        case .scheduled: return "Programmato"
        case .info: return "Informazione"
        }
    }
}

nonisolated struct InfoItem: Identifiable, Sendable {
    let id: String               // attributo id dell'HTML: stato aperto/scroll sopravvivono al reload
    let title: String
    let date: String
    let text: AttributedString   // con grassetti e a capo del sito
    let links: [InfoLink]
    let color: String?           // left-bar: "green" | "red" | "orange"
    let tags: [InfoTag]

    var severity: InfoSeverity { InfoSeverity(color: color) }
    var isHighlighted: Bool { tags.contains { $0.highlighted } }

    /// Vero se l'avviso linka la corsa indicata. Origine e giorno, se presenti,
    /// devono coincidere: lo stesso numero circola ogni giorno e da origini diverse.
    func mentions(train number: String, origin: String?, day: Date?) -> Bool {
        links.contains { $0.trainRef?.matches(number: number, origin: origin, day: day) ?? false }
    }

    /// Ricerca senza distinzione di maiuscole e accenti su tutti i testi visibili.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [title, date, String(text.characters)]
            + tags.map(\.label)
            + links.map(\.label)
            + links.compactMap { $0.trainRef?.numero }
        return fields.contains { $0.localizedStandardContains(q) }
    }
}

nonisolated extension ExactTrenitaliaRef {
    /// Confronto con numero (senza zeri iniziali), codice origine ViaggiaTreno
    /// (es. "S01700") e giorno di calendario a Roma.
    func matches(number: String, origin: String?, day: Date?) -> Bool {
        func norm(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            let stripped = t.drop { $0 == "0" }
            return stripped.isEmpty ? t : String(stripped)
        }
        guard norm(numero) == norm(number) else { return false }
        if let origin, !origin.isEmpty,
           origin.trimmingCharacters(in: .whitespaces).uppercased() != codOrigine.uppercased() {
            return false
        }
        if let day {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Europe/Rome") ?? .current
            let runDate = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
            guard cal.isDate(runDate, inSameDayAs: day) else { return false }
        }
        return true
    }
}

nonisolated enum InfomobilitaError: Error { case invalidURL, invalidResponse, parsing }

nonisolated enum InfomobilitaService {

    private static let urlString =
        "https://www.trenitalia.com/it/informazioni/Infomobilita/notizie-infomobilita.html"

    /// Base per risolvere gli href relativi (link ai PDF, pagine del sito).
    private static var pageURL: URL? { URL(string: urlString) }

    // @concurrent: download e parsing (regex su tutta la pagina) fuori dal main thread.
    @concurrent
    static func fetch() async throws -> [InfoItem] {
        guard let url = pageURL else { throw InfomobilitaError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw InfomobilitaError.invalidResponse
        }
        let items = parse(html)
        // Pagina non vuota ma nessun avviso: struttura cambiata, non "nessun avviso".
        if items.isEmpty && !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw InfomobilitaError.parsing
        }
        return items
    }

    /// True se un avviso di infomobilità linka il treno indicato.
    @MainActor
    static func containsTrain(_ number: String) async -> Bool {
        await containsTrain(number, origin: nil, day: nil)
    }

    /// True se un avviso linka la corsa indicata: numero e, se forniti, codice
    /// origine ViaggiaTreno e giorno (Europe/Rome). Usa la cache condivisa.
    @MainActor
    static func containsTrain(_ number: String, origin: String?, day: Date?) async -> Bool {
        guard let items = try? await InfomobilitaStore.shared.load() else { return false }
        return items.contains { $0.mentions(train: number, origin: origin, day: day) }
    }

    // MARK: - Parsing

    static func parse(_ html: String) -> [InfoItem] {
        // Ogni avviso inizia con un tag la cui lista di classi contiene
        // "infomobility" (non "infomobility-title" ecc.), in qualsiasi ordine.
        let opener = "<([a-z][a-z0-9]*)\\b[^>]*\\sclass\\s*=\\s*[\"'](?:[^\"']*\\s)?infomobility(?:\\s[^\"']*)?[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: opener, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        let openers = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var items: [InfoItem] = []
        var usedIDs: Set<String> = []

        for (i, m) in openers.enumerated() {
            let end = i + 1 < openers.count ? openers[i + 1].range.location : ns.length
            let openTag = ns.substring(with: m.range)
            let chunk = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))

            guard let rawTitle = firstGroup(chunk, "infomobility-title[^>]*>(.*?)</h[1-6]>")
                    ?? firstGroup(chunk, "infomobility-title[^>]*>(.*?)</(?:div|p|span|a)>") else { continue }
            let title = cleanText(rawTitle)
            guard !title.isEmpty else { continue }
            let rawDate = firstGroup(chunk, "infomobility-date[^>]*>(.*?)</(?:p|span|div|time)>") ?? ""
            let date = cleanText(rawDate)
            let body = descriptionBody(chunk) ?? ""

            // Sostituisce ogni link con un riferimento "(N)" nel punto in cui si
            // trovava, così il testo resta scorrevole e i link vanno in fondo.
            let (text, links) = parseBody(body)

            // id dall'HTML; in mancanza un hash stabile di titolo e data.
            var id = firstGroup(openTag, "\\sid\\s*=\\s*[\"']([^\"']+)[\"']")
                ?? "info-\(stableHash(title + "|" + date))"
            if usedIDs.contains(id) {
                var n = 2
                while usedIDs.contains("\(id)-\(n)") { n += 1 }
                id = "\(id)-\(n)"
            }
            usedIDs.insert(id)

            items.append(InfoItem(
                id: id,
                title: title,
                date: date,
                text: text,
                links: links,
                color: firstGroup(chunk, "left-bar\\s+(\\w+)")?.lowercased(),
                tags: parseTags(chunk)
            ))
        }
        return items
    }

    /// Contenuto del box "description": bilancia i tag annidati invece di
    /// fermarsi al primo `</div>`.
    private static func descriptionBody(_ chunk: String) -> String? {
        let pattern = "<([a-z][a-z0-9]*)\\b[^>]*\\sclass\\s*=\\s*[\"'][^\"']*\\bdescription\\b[^\"']*[\"'][^>]*>"
        guard let open = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = chunk as NSString
        guard let m = open.firstMatch(in: chunk, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let tag = ns.substring(with: m.range(at: 1))
        let start = m.range.location + m.range.length

        guard let tokens = try? NSRegularExpression(pattern: "<(/?)\(tag)\\b[^>]*>", options: [.caseInsensitive]) else {
            return ns.substring(from: start)
        }
        var depth = 1
        for t in tokens.matches(in: chunk, range: NSRange(location: start, length: ns.length - start)) {
            let token = ns.substring(with: t.range)
            if ns.substring(with: t.range(at: 1)) == "/" {
                depth -= 1
                if depth == 0 {
                    return ns.substring(with: NSRange(location: start, length: t.range.location - start))
                }
            } else if !token.hasSuffix("/>") {
                depth += 1
            }
        }
        // HTML non bilanciato: fino alla fine dell'avviso.
        return ns.substring(from: start)
    }

    /// Estrae i tag ("In evidenza", regione…) mostrati nel box collassato.
    private static func parseTags(_ chunk: String) -> [InfoTag] {
        let pattern = "tag-category\\s+([\\w-]+)[^\"']*[\"'][^>]*>(.*?)</(?:div|span)>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = chunk as NSString
        var tags: [InfoTag] = []
        for m in regex.matches(in: chunk, range: NSRange(location: 0, length: ns.length)) {
            let colorClass = ns.substring(with: m.range(at: 1)).lowercased()
            let label = cleanText(ns.substring(with: m.range(at: 2)))
            guard !label.isEmpty else { continue }
            tags.append(InfoTag(id: "\(tags.count)-\(label)", label: label, highlighted: colorClass == "blu"))
        }
        return tags
    }

    private static func parseBody(_ body: String) -> (text: AttributedString, links: [InfoLink]) {
        let pattern = "<a[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return (attributedText(body), [])
        }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var result = ""
        var links: [InfoLink] = []
        var lastEnd = 0
        var number = 0

        for m in matches {
            // Testo prima dell'anchor.
            result += ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            lastEnd = m.range.location + m.range.length

            // Decodifica "&amp;" ecc.: negli URL i parametri sono uniti da "&amp;".
            let href = decodeEntities(ns.substring(with: m.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = cleanText(ns.substring(with: m.range(at: 2)))
            guard !label.isEmpty else { continue }   // scarta gli anchor vuoti

            number += 1
            result += " (\(number)) "
            let ref = trainRef(from: href)
            // Generico solo se è "cerca treno" SENZA i parametri della corsa.
            let isGeneric = ref == nil && href.lowercased().contains("cercatreno")
            links.append(InfoLink(number: number,
                                  label: label,
                                  url: resolveURL(href),
                                  trainRef: ref,
                                  isGenericSearch: isGeneric))
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))

        return (attributedText(result), links)
    }

    /// Href relativi ("/content/…/avviso.pdf") risolti rispetto alla pagina:
    /// altrimenti `openURL` non fa nulla.
    private static func resolveURL(_ href: String) -> URL? {
        let lower = href.lowercased()
        guard !href.isEmpty, !href.hasPrefix("#"), !lower.hasPrefix("javascript:") else { return nil }
        return URL(string: href, relativeTo: pageURL)?.absoluteURL
    }

    /// Converte il corpo HTML in testo attribuito preservando grassetti e a capo.
    private static func attributedText(_ html: String) -> AttributedString {
        var s = replaceAll(html, "<br\\s*/?>", with: "\n")
        s = replaceAll(s, "</p>", with: "\n")
        // Sentinelle per il grassetto (<b>/<strong>).
        s = replaceAll(s, "<(b|strong)(\\s[^>]*)?>", with: "\u{1}")
        s = replaceAll(s, "</(b|strong)>", with: "\u{2}")
        s = replaceAll(s, "<[^>]+>", with: "")
        s = decodeEntities(s)
        s = replaceAll(s, "[ \\t]+", with: " ")

        // Righe non vuote (ignorando le sentinelle del grassetto), separate da
        // UNA sola riga vuota: normalizza i grandi spazi dell'HTML.
        let lines = s.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let visible = trimmed
                .replacingOccurrences(of: "\u{1}", with: "")
                .replacingOccurrences(of: "\u{2}", with: "")
                .trimmingCharacters(in: .whitespaces)
            return visible.isEmpty ? nil : trimmed
        }
        let normalized = lines.joined(separator: "\n\n")

        var result = AttributedString()
        var bold = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            if bold { run.inlinePresentationIntent = .stronglyEmphasized }
            result.append(run)
            buffer = ""
        }
        for ch in normalized {
            if ch == "\u{1}" { flush(); bold = true }
            else if ch == "\u{2}" { flush(); bold = false }
            else { buffer.append(ch) }
        }
        flush()
        return result
    }

    /// Ricava la corsa esatta da un link treno (formato API o web).
    /// API:  .../andamentoTreno/S09818/798/1783807200000
    /// Web:  .../cercaTreno.jsp?treno=798&origine=S09818&datapartenza=1783807200000
    private static func trainRef(from href: String) -> ExactTrenitaliaRef? {
        if let m = firstGroups(href, "andamentoTreno/([^/]+)/([0-9]+)/([0-9]+)"),
           let ts = Int(m[2]) {
            return ExactTrenitaliaRef(codOrigine: m[0], numero: m[1], timestamp: ts)
        }
        let lower = href.lowercased()
        if lower.contains("cercatreno") || lower.contains("viaggiatreno") {
            // Estrazione diretta dei parametri (robusta anche con URL non standard).
            if let treno = firstGroup(href, "[?&]treno=([0-9]+)"),
               let origine = firstGroup(href, "[?&]origine=([A-Za-z0-9]+)"),
               let ts = firstGroup(href, "[?&]datapartenza=([0-9]+)").flatMap(Int.init) {
                return ExactTrenitaliaRef(codOrigine: origine, numero: treno, timestamp: ts)
            }
        }
        return nil
    }

    /// Come `firstGroup` ma restituisce tutti i gruppi catturati.
    private static func firstGroups(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1 else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            groups.append(String(text[r]))
        }
        return groups
    }

    // MARK: - Helper HTML/regex

    private static func firstGroup(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func replaceAll(_ text: String, _ pattern: String, with repl: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: repl)
    }

    /// Rimuove i tag e decodifica le entità principali (per titolo/etichette).
    private static func cleanText(_ html: String) -> String {
        decodeEntities(replaceAll(html, "<[^>]+>", with: " "))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodifica in un solo passaggio entità numeriche (&#232; &#xE8;) e con
    /// nome: un solo passaggio evita la doppia decodifica di "&amp;lt;".
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});")
        else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += entityValue(name) ?? ns.substring(with: m.range)   // sconosciuta: lasciata com'è
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func entityValue(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.first == "x" || digits.first == "X" {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits)
            }
            guard let code, code != 0 else { return nil }
            if code == 160 { return " " }   // nbsp come spazio normale, come &nbsp;
            return Unicode.Scalar(code).map { String(Character($0)) }
        }
        if let v = namedEntities[name] { return v }
        // Latin-1 (160…255) nell'ordine standard HTML.
        if let i = latin1Names.firstIndex(of: name), let scalar = Unicode.Scalar(UInt32(160 + i)) {
            return i == 0 ? " " : String(Character(scalar))
        }
        return nil
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "euro": "€", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’",
        "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "hellip": "…",
        "bull": "•", "trade": "™", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "lsaquo": "‹", "rsaquo": "›", "OElig": "Œ", "oelig": "œ", "Scaron": "Š",
        "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜",
        "ensp": " ", "emsp": " ", "thinsp": " ", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "prime": "′", "Prime": "″", "minus": "−",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
    ]

    private static let latin1Names: [String] = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect",
        "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
        "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
        "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
        "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil",
        "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
        "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times",
        "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
        "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil",
        "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
        "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide",
        "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
    ]

    /// Hash FNV-1a: deterministico tra un avvio e l'altro (a differenza di `hashValue`).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// MARK: - Cache condivisa

/// Cache in memoria condivisa tra InfomobilitaView e il banner del dettaglio
/// treno: aprire un treno non riscarica la pagina ogni volta.
@MainActor
final class InfomobilitaStore {
    static let shared = InfomobilitaStore()
    static let ttl: TimeInterval = 5 * 60

    private(set) var items: [InfoItem]?
    private(set) var fetchedAt: Date?
    private var inFlight: Task<[InfoItem], Error>?

    var isFresh: Bool {
        guard let fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) < Self.ttl
    }

    /// Avvisi dalla cache se recenti, altrimenti dalla rete. In caso di errore
    /// la cache precedente resta intatta.
    func load(force: Bool = false) async throws -> [InfoItem] {
        if !force, isFresh, let items { return items }
        // Vista e banner del treno insieme: un solo download condiviso.
        if let inFlight { return try await inFlight.value }
        let task = Task { try await InfomobilitaService.fetch() }
        inFlight = task
        defer { inFlight = nil }
        let fetched = try await task.value
        items = fetched
        fetchedAt = Date()
        return fetched
    }
}
