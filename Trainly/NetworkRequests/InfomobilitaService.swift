//
//  InfomobilitaService.swift
//  Trainly
//
//  Scraping della pagina Infomobilità di Trenitalia.
//  I contenuti (anche quelli nelle sezioni collassate) sono nell'HTML.
//

import Foundation

struct InfoLink: Identifiable {
    let id = UUID()
    let number: Int            // riferimento "(1)", "(2)"… nel testo
    let label: String
    let url: URL?
    let trainRef: ExactTrenitaliaRef?  // link a una corsa esatta (origine+numero+data)
    let isGenericSearch: Bool          // link "cerca treno" generico -> tab Cerca
}

struct InfoTag: Identifiable {
    let id = UUID()
    let label: String
    let highlighted: Bool   // "In evidenza" (tag blu) -> badge giallo
}

struct InfoItem: Identifiable {
    let id = UUID()
    let title: String
    let date: String
    let text: AttributedString   // con grassetti e a capo del sito
    let links: [InfoLink]
    let color: String?           // left-bar: "green" | "red" | "orange"
    let tags: [InfoTag]
}

enum InfomobilitaError: Error { case invalidURL, invalidResponse }

enum InfomobilitaService {

    private static let urlString =
        "https://www.trenitalia.com/it/informazioni/Infomobilita/notizie-infomobilita.html"

    static func fetch() async throws -> [InfoItem] {
        guard let url = URL(string: urlString) else { throw InfomobilitaError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw InfomobilitaError.invalidResponse
        }
        return parse(html)
    }

    /// True se un avviso di infomobilità linka il treno indicato.
    static func containsTrain(_ number: String) async -> Bool {
        guard let items = try? await fetch() else { return false }
        return items.contains { item in
            item.links.contains { $0.trainRef?.numero == number }
        }
    }

    // MARK: - Parsing

    static func parse(_ html: String) -> [InfoItem] {
        // Ogni avviso inizia con class="infomobility" id=...
        let chunks = html.components(separatedBy: "class=\"infomobility\" id=")
        var items: [InfoItem] = []

        for chunk in chunks.dropFirst() {
            guard let rawTitle = firstGroup(chunk, "infomobility-title[^>]*>(.*?)</h3>") else { continue }
            let rawDate = firstGroup(chunk, "infomobility-date[^>]*>(.*?)</p>") ?? ""
            let body = firstGroup(chunk, "description richtext\">(.*?)</div>") ?? ""

            // Sostituisce ogni link con un riferimento "(N)" nel punto in cui si
            // trovava, così il testo resta scorrevole e i link vanno in fondo.
            let (text, links) = parseBody(body)

            items.append(InfoItem(
                title: cleanText(rawTitle),
                date: cleanText(rawDate),
                text: text,
                links: links,
                color: firstGroup(chunk, "left-bar\\s+(\\w+)")?.lowercased(),
                tags: parseTags(chunk)
            ))
        }
        return items
    }

    /// Estrae i tag ("In evidenza", regione…) mostrati nel box collassato.
    private static func parseTags(_ chunk: String) -> [InfoTag] {
        let pattern = "tag-category\\s+(\\w+)\"[^>]*>(.*?)</div>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = chunk as NSString
        var tags: [InfoTag] = []
        for m in regex.matches(in: chunk, range: NSRange(location: 0, length: ns.length)) {
            let colorClass = ns.substring(with: m.range(at: 1)).lowercased()
            let label = cleanText(ns.substring(with: m.range(at: 2)))
            guard !label.isEmpty else { continue }
            tags.append(InfoTag(label: label, highlighted: colorClass == "blu"))
        }
        return tags
    }

    private static func parseBody(_ body: String) -> (text: AttributedString, links: [InfoLink]) {
        let pattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
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
            let label = cleanText(ns.substring(with: m.range(at: 2)))
            guard !label.isEmpty else { continue }   // scarta gli anchor vuoti

            number += 1
            result += " (\(number)) "
            let ref = trainRef(from: href)
            // Generico solo se è "cerca treno" SENZA i parametri della corsa.
            let isGeneric = ref == nil && href.lowercased().contains("cercatreno")
            links.append(InfoLink(number: number,
                                  label: label,
                                  url: URL(string: href),
                                  trainRef: ref,
                                  isGenericSearch: isGeneric))
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))

        return (attributedText(result), links)
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

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&#39;": "'", "&apos;": "'",
                   "&quot;": "\"", "&egrave;": "è", "&agrave;": "à", "&ograve;": "ò",
                   "&igrave;": "ì", "&ugrave;": "ù", "&eacute;": "é", "&lt;": "<", "&gt;": ">"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
