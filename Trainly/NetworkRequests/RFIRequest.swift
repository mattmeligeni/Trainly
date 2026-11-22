import Foundation

// `nonisolated`: il modello viene creato dal parsing, che gira fuori dal main actor.
nonisolated struct RFITrain: Codable, Identifiable, Sendable {
    let treno: String
    let vettore: String
    let categoria: String
    let destinazione: String   // in Arrivi è la provenienza
    let orario: String
    let ritardo: String        // testo grezzo della cella: "" = nessuna informazione
    let binario: String
    let inPartenza: Bool
    let fermate: String        // "Fermate successive" (solo in Partenze)
    var informazioni: String = ""   // note del popup, es. "CARROZZA 1 IN CODA AL TRENO"

    var id: String { "\(treno)-\(orario)-\(destinazione)" }
}

nonisolated extension RFITrain {
    /// Nome imageset del logo vettore da mostrare nel tabellone.
    var logoImageName: String? {
        let v = vettore.uppercased()
        let c = categoria.uppercased()
        if v.contains("FRECCIAROSSA") { return "FRECCIAROSSA" }
        if v.contains("FRECCIARGENTO") { return "FRECCIARGENTO" }
        if v.contains("FRECCIABIANCA") { return "FRECCIABIANCA" }
        if v.contains("LEONARDO") { return "LEONARDOEXP" }
        if v == "ITALO" { return "ITALO" }
        if v.contains("TPER") { return "TRENITALIA_TPER" }
        if v.contains("TRENORD") { return "TRENORD-2" }
        if v.contains("INTERCITY") { return "INTERCITY-2" }
        if v.contains("TRENITALIA") {
            // EC (EuroCity) usa il logo Trenitalia generico, gli altri il regionale.
            if c.contains("EC") || c.contains("EUROCITY") { return "TRENITALIA" }
            return "TRENITALIA-3"
        }
        return nil
    }

    /// Categoria senza il prefisso "Categoria ".
    var categoryLabel: String {
        categoria
            .replacingOccurrences(of: "Categoria", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
    }

    /// Etichetta descrittiva "Operatore Tipo" mostrata nel tabellone.
    var badgeLabel: String {
        let v = vettore.uppercased()
        if v.contains("FRECCIAROSSA") { return "Trenitalia Frecciarossa" }
        if v.contains("FRECCIARGENTO") { return "Trenitalia Frecciargento" }
        if v.contains("FRECCIABIANCA") { return "Trenitalia Frecciabianca" }
        if v.contains("LEONARDO") { return "Leonardo Express" }
        if v == "ITALO" { return "Alta Velocità ITALO" }
        if v.contains("INTERCITY") { return "Trenitalia Intercity" }
        if v.contains("TPER") { return "Trenitalia TPER" }
        if v.contains("TRENORD") { return "Trenord" }
        if v.contains("TRENITALIA") {
            return categoria.uppercased().contains("EC") ? "Trenitalia EuroCity" : "Trenitalia Regionale"
        }
        let base = vettore.capitalized
        return categoryLabel.isEmpty ? base : "\(base) \(categoryLabel.capitalized)"
    }

    /// Vettore dell'app (rawValue di `vector`) per aprire la ricerca.
    var searchVector: String {
        let v = vettore.uppercased()
        if v == "ITALO" { return "Italo" }
        if v.contains("TRENORD") { return "Trenord" }
        // Gli altri operatori (anche esteri) passano da ViaggiaTreno, che riporta
        // la circolazione sull'intera rete RFI, non solo i treni Trenitalia.
        return "Trenitalia"   // FRECCIAROSSA/INTERCITY/EC/REG/TPER -> ViaggiaTreno
    }

    /// Ritardo numerico se disponibile.
    /// Ritardo in minuti: nil se la cella è vuota o non numerica,
    /// negativo se il treno è in anticipo.
    var delayMinutes: Int? {
        let raw = ritardo.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return Int(raw.replacingOccurrences(of: "\u{2212}", with: "-"))   // anche il segno meno tipografico
    }

    /// Testo di stato non numerico (es. "RITARDO", "SOPPRESSO"), se presente.
    var statusText: String? {
        let raw = ritardo.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, delayMinutes == nil else { return nil }
        return raw
    }
}

// MARK: - Errori

nonisolated enum RFIError: LocalizedError, Equatable {
    case badStatus(Int)
    case unexpectedFormat

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "Il server RFI ha risposto con un errore (codice \(code))."
        case .unexpectedFormat:
            return "Il formato del tabellone RFI è cambiato: impossibile leggere i treni."
        }
    }
}

// MARK: - Servizio

struct RFIService {
    static let baseURL = "https://iechub.rfi.it/ArriviPartenze/ArrivalsDepartures/Monitor"

    static func getTrains(placeId: String = "1728", arrivals: Bool = true) async throws -> [RFITrain] {
        let urlString = "\(baseURL)?placeId=\(placeId)&arrivals=\(arrivals)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        // Una pagina d'errore del server non deve diventare "Nessuna partenza".
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RFIError.badStatus(http.statusCode)
        }

        return try await RFIParser.parse(data)
    }
}

// MARK: - Parsing (fuori dal main actor)

nonisolated enum RFIParser {

    /// `@concurrent`: con l'isolamento predefinito MainActor e la concorrenza
    /// "approachable", senza questo il parsing girerebbe sul main actor.
    @concurrent
    static func parse(_ data: Data) async throws -> [RFITrain] {
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeRawData)
        }
        return try parseHTML(html)
    }

    static func parseHTML(_ html: String) throws -> [RFITrain] {
        var trains: [RFITrain] = []

        // Pagina non vuota ma senza la tabella del monitor: il markup è cambiato.
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard html.contains("id=\"monitor\"") || html.contains("bodyTabId") else {
            throw RFIError.unexpectedFormat
        }

        // L'HTML è multi-linea: serve dotMatchesNewlines, altrimenti (.*?) non
        // attraversa i newline e non matcha nessuna riga.
        let rowPattern = (/<tr[^>]*id="(\d+)"[^>]*>(.*?)<\/tr>/).dotMatchesNewlines()
        let cellPattern = (/<td[^>]*>(.*?)<\/td>/).dotMatchesNewlines()
        let imgAltPattern = /alt="([^"]+)"/
        // Il popup ha più blocchi (Fermate successive, Informazioni): si cerca per titolo.
        let fermatePattern = (/Fermate successive\s*<\/div>\s*<div[^>]*testoinfoaggiuntive[^>]*>(.*?)<\/div>/).dotMatchesNewlines()
        let infoPattern = (/>\s*Informazioni\s*<\/div>\s*<div[^>]*testoinfoaggiuntive[^>]*>(.*?)<\/div>/).dotMatchesNewlines()

        var rowCount = 0
        for match in html.matches(of: rowPattern) {
            rowCount += 1
            let rowHTML = String(match.2)
            let cells = rowHTML.matches(of: cellPattern).map { String($0.1) }

            guard cells.count >= 9 else { continue }

            let vettoreAlt = cells[0].firstMatch(of: imgAltPattern).map { String($0.1) } ?? ""
            let categoriaAlt = cells[1].firstMatch(of: imgAltPattern).map { String($0.1) } ?? ""
            let fermateText = cells[8].firstMatch(of: fermatePattern).map { String($0.1) } ?? ""
            let infoText = cells[8].firstMatch(of: infoPattern).map { String($0.1) } ?? ""

            let train = RFITrain(
                treno: stripHTML(cells[2]),
                vettore: decodeHTMLEntities(vettoreAlt),
                categoria: decodeHTMLEntities(categoriaAlt),
                destinazione: decodeHTMLEntities(stripHTML(cells[3])),
                orario: stripHTML(cells[4]),
                // Cella vuota = nessuna informazione sul ritardo (non "in orario").
                ritardo: decodeHTMLEntities(stripHTML(cells[5])),
                binario: decodeHTMLEntities(stripHTML(cells[6])),
                // In arrivo/partenza: la cella contiene un'immagine "Lampeggio*"
                // (Gold o Grey, entrambe alt="Si"); vuota se non segnalato.
                inPartenza: cells[7].contains("Lampeggio"),
                fermate: decodeHTMLEntities(stripHTML(fermateText)),
                informazioni: decodeHTMLEntities(stripHTML(infoText))
            )

            trains.append(train)
        }

        // Righe presenti ma nessuna leggibile: le celle sono cambiate.
        if rowCount > 0 && trains.isEmpty {
            throw RFIError.unexpectedFormat
        }

        return trains
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entità con nome più comuni nelle pagine RFI (e nei testi italiani).
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "agrave": "à", "aacute": "á", "egrave": "è", "eacute": "é", "igrave": "ì",
        "iacute": "í", "ograve": "ò", "oacute": "ó", "ugrave": "ù", "uacute": "ú",
        "Agrave": "À", "Egrave": "È", "Eacute": "É", "Igrave": "Ì", "Ograve": "Ò",
        "Ugrave": "Ù", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä",
        "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "ccedil": "ç", "Ccedil": "Ç",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "laquo": "«",
        "raquo": "»", "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·",
        "deg": "°", "euro": "€",
    ]

    /// Decodifica entità HTML come &apos; &#39; &amp; &quot; etc.
    /// Decodifica manuale (anche &#x27;) senza NSAttributedString,
    /// che usa WebKit, è lento e richiede il main thread.
    static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        result.reserveCapacity(string.count)
        var i = string.startIndex
        while i < string.endIndex {
            let ch = string[i]
            guard ch == "&",
                  let semi = string[i...].prefix(12).firstIndex(of: ";") else {
                result.append(ch)
                i = string.index(after: i)
                continue
            }
            let name = string[string.index(after: i)..<semi]
            if let decoded = decodeEntity(name) {
                result += decoded
                i = string.index(after: semi)
            } else {
                // Entità sconosciuta: lasciata com'è.
                result.append(ch)
                i = string.index(after: i)
            }
        }
        return result
    }

    private static func decodeEntity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let body = name.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)]
    }
}
