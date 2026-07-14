import Foundation
internal import UIKit

struct RFITrain: Codable, Identifiable {
    let treno: String
    let vettore: String
    let categoria: String
    let destinazione: String
    let orario: String
    let ritardo: String
    let binario: String
    let inPartenza: Bool
    let fermate: String

    var id: String { "\(treno)-\(orario)-\(destinazione)" }
}

extension RFITrain {
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
        return "Trenitalia"   // FRECCIAROSSA/INTERCITY/EC/REG/TPER -> ViaggiaTreno
    }

    /// Ritardo numerico se disponibile.
    var delayMinutes: Int? { Int(ritardo.trimmingCharacters(in: .whitespaces)) }
}

struct RFIService {
    static let baseURL = "https://iechub.rfi.it/ArriviPartenze/ArrivalsDepartures/Monitor"
    
    static func getTrains(placeId: String = "1728", arrivals: Bool = true) async throws -> [RFITrain] {
        let urlString = "\(baseURL)?placeId=\(placeId)&arrivals=\(arrivals)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        
        return parseHTML(html)
    }
    
    private static func parseHTML(_ html: String) -> [RFITrain] {
        var trains: [RFITrain] = []
        
        // L'HTML è multi-linea: serve dotMatchesNewlines, altrimenti (.*?) non
        // attraversa i newline e non matcha nessuna riga.
        let rowPattern = (/<tr[^>]*id="(\d+)"[^>]*>(.*?)<\/tr>/).dotMatchesNewlines()
        let cellPattern = (/<td[^>]*>(.*?)<\/td>/).dotMatchesNewlines()
        let imgAltPattern = /alt="([^"]+)"/
        let fermatePattern = (/testoinfoaggiuntive[^>]*>(.*?)<\/div>/).dotMatchesNewlines()
        
        for match in html.matches(of: rowPattern) {
            let rowHTML = String(match.2)
            let cells = rowHTML.matches(of: cellPattern).map { String($0.1) }
            
            guard cells.count >= 9 else { continue }
            
            let vettoreAlt = cells[0].firstMatch(of: imgAltPattern).map { String($0.1) } ?? ""
            let categoriaAlt = cells[1].firstMatch(of: imgAltPattern).map { String($0.1) } ?? ""
            let fermateText = cells[8].firstMatch(of: fermatePattern).map { String($0.1) } ?? ""
            
            let train = RFITrain(
                treno: stripHTML(cells[2]),
                vettore: decodeHTMLEntities(vettoreAlt),
                categoria: decodeHTMLEntities(categoriaAlt),
                destinazione: decodeHTMLEntities(stripHTML(cells[3])),
                orario: stripHTML(cells[4]),
                ritardo: stripHTML(cells[5]).isEmpty ? "0" : stripHTML(cells[5]),
                binario: stripHTML(cells[6]),
                // In arrivo/partenza: la cella contiene un'immagine "Lampeggio*"
                // (Gold o Grey, entrambe alt="Si"); vuota se non segnalato.
                inPartenza: cells[7].contains("Lampeggio"),
                fermate: decodeHTMLEntities(fermateText)
            )
            
            trains.append(train)
        }
        
        return trains
    }
    
    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Decodifica entità HTML come &apos; &#39; &amp; &quot; etc.
    private static func decodeHTMLEntities(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return string }
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        return string
    }
}
