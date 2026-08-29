//
//  BigliettiModels.swift
//  Trainly
//
//  Ricerca biglietti Trenitalia (lefrecce BFF).
//

import Foundation

// MARK: - Vettore

enum TicketCarrier: String, Codable {
    case trenitalia, italo, trenord
}

// MARK: - Filtri e ordinamento (condivisi da tutte le liste soluzioni)

enum ChangesFilter: String, CaseIterable, Identifiable {
    case direct = "Diretto", max1 = "Max 1 cambio", max2 = "Max 2 cambi"
    var id: String { rawValue }
    var maxChanges: Int {
        switch self {
        case .direct: return 0
        case .max1: return 1
        case .max2: return 2
        }
    }
}

enum TicketSort: String, CaseIterable, Identifiable {
    case priceAsc = "Prezzo crescente", priceDesc = "Prezzo decrescente", duration = "Durata"
    var id: String { rawValue }
}

extension Array where Element == TicketSolution {
    /// Applica filtro sui cambi e ordinamento; le soluzioni senza prezzo/durata
    /// finiscono in fondo.
    func filteredSorted(changes: ChangesFilter, sort: TicketSort) -> [TicketSolution] {
        var result = filter { $0.changes <= changes.maxChanges }
        switch sort {
        case .priceAsc:
            result.sort { ($0.minPrice ?? .greatestFiniteMagnitude) < ($1.minPrice ?? .greatestFiniteMagnitude) }
        case .priceDesc:
            result.sort { ($0.minPrice ?? -1) > ($1.minPrice ?? -1) }
        case .duration:
            result.sort { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) }
        }
        return result
    }
}

/// Parsing durata testuale (es. "8h 30min", "1h 05m", "35min") in minuti.
enum TicketDuration {
    static func minutes(_ text: String) -> Int? {
        var total = 0
        var matched = false
        if let h = firstGroup(#"(\d+)\s*h"#, in: text) { total += h * 60; matched = true }
        if let m = firstGroup(#"(\d+)\s*m"#, in: text) { total += m; matched = true }
        return matched ? total : nil
    }

    private static func firstGroup(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// Nome stazione normalizzato per il confronto tra cataloghi di vettori diversi
/// (Trenitalia "Milano Centrale" ↔ Trenord "MILANO CENTRALE" ↔ Italo "Milano
/// Centrale"): maiuscolo, senza accenti e con spazi/punteggiatura ridotti.
func normalizedStationName(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let cleaned = folded.uppercased().unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    }
    return String(cleaned).split(separator: " ").joined(separator: " ")
}

// MARK: - Stazione (locations/search)

struct TrenitaliaLocation: Codable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let displayName: String?

    var label: String { displayName ?? name ?? "\(id)" }
}

// MARK: - Risposta grezza (ticket/solutions) — tutti opzionali per robustezza

struct SolutionsResponse: Codable {
    let solutions: [RawSolution]?
}

struct RawSolution: Codable {
    let solution: RawSolutionInfo?
    let grids: [RawGrid]?
    let messages: [RawMessage?]?    // il feed può contenere elementi null
    let co2Emission: RawCO2?
}

struct RawSolutionInfo: Codable {
    let id: String?
    let origin: String?
    let destination: String?
    let departureTime: String?
    let arrivalTime: String?
    let duration: String?
    let status: String?
    let trains: [RawTrain]?
    let price: RawPrice?
}

struct RawTrain: Codable {
    let denomination: String?
    let name: String?
    let acronym: String?
    let trainCategory: String?
}

struct RawGrid: Codable {
    let summaries: [RawSummary]?
    let services: [RawService]?
}

struct RawSummary: Codable {
    let name: String?
    let departureTime: String?
    let arrivalTime: String?
    let duration: String?
    let departureLocationName: String?
    let arrivalLocationName: String?
    let trainInfo: RawTrain?
}

struct RawService: Codable {
    let name: String?
    let shortName: String?
    let groupName: String?
    let offers: [RawOffer]?
}

struct RawOffer: Codable {
    let name: String?
    let price: RawPrice?
    let availableAmount: Int?
    let status: String?
    let canRefund: Bool?
    let canChange: Bool?
    let selected: Bool?
}

struct RawPrice: Codable {
    let currency: String?
    let amount: Double?
}

struct RawMessage: Codable {
    let message: String?
    let status: String?
}

struct RawCO2: Codable {
    let summaryTitle: String?
}

// MARK: - Modelli parsati (per la UI)

struct TicketSolution: Identifiable {
    let id: String
    let origin: String
    let destination: String
    let departure: String   // "HH:mm"
    let arrival: String
    let duration: String
    let status: String      // SALEABLE | SOLD_OUT | UNAVAILABLE
    let direct: Bool
    let changes: Int
    let trains: [TicketTrain]
    let services: [TicketService]
    let minPrice: Double?
    let messages: [String]
    let co2: String?
    var carrier: TicketCarrier = .trenitalia
    var durationMinutes: Int? = nil

    var isSaleable: Bool { status == "SALEABLE" }
    var hasTrenord: Bool { trains.contains(where: \.isTrenord) }

    /// Soluzione composta esclusivamente da treni Trenord: nella lista Trenitalia
    /// (lefrecce) va nascosta perché ora Trenord ha una sezione dedicata.
    var isPureTrenord: Bool { !trains.isEmpty && trains.allSatisfy(\.isTrenord) }
}

struct TicketTrain: Identifiable {
    let id = UUID()
    let label: String            // "S13" (SU) oppure "RE 10479"
    let departure: String
    let arrival: String
    let departureStation: String
    let arrivalStation: String
    let isTrenord: Bool
    let logoImageName: String?   // imageset del logo (Trenord incluso)
    // Extra opzionali (popolati dove disponibili, es. Trenord). nil = da nascondere.
    var bikeAllowed: Bool? = nil
    var accessible: Bool? = nil
    var secondClassOnly: Bool? = nil
    var crowdingPercent: Int? = nil
    var crowdingLabel: String? = nil
    var delayMinutes: Int? = nil

    /// Nome mostrato: per i suburbani Trenord (SU) la prima parola della
    /// denominazione (es. "S13"), altrimenti acronimo + numero (es. "RE 10479").
    static func makeLabel(acronym: String?, name: String?, denomination: String?) -> String {
        if (acronym ?? "").uppercased() == "SU" {
            return (denomination ?? "").split(separator: " ").first.map(String.init) ?? (name ?? "")
        }
        return "\(acronym ?? "") \(name ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// Mappa il treno al nome imageset in Assets. I treni Trenord che appaiono
    /// nella ricerca Trenitalia hanno "TRENORD" nella denominazione.
    static func logo(acronym: String?, denomination: String?) -> String? {
        let d = (denomination ?? "").uppercased()
        let a = (acronym ?? "").uppercased()
        if d.contains("TRENORD") { return "TRENORD-2" }
        if d.contains("LEONARDO") || a == "LE" { return "LEONARDOEXP" }
        switch a {
        case "FR": return "FRECCIAROSSA"
        case "FA": return "FRECCIARGENTO"
        case "FB": return "FRECCIABIANCA"
        case "IC", "ICN", "EN", "NI": return "INTERCITY-2"
        case "EC": return "TRENITALIA"
        case "RV", "RE", "REG", "R", "SU", "MET", "S": return "TRENITALIA-3"
        default: return nil
        }
    }
}

struct TicketService: Identifiable {
    let id = UUID()
    let group: String
    let offers: [TicketOffer]
}

struct TicketOffer: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double?
    let seats: Int
    let status: String
    let refundable: Bool?      // nil = informazione non disponibile (nessuna icona)
    let changeable: Bool?
    var detail: String? = nil  // testo aggiuntivo (es. penali Italo)
}

// MARK: - Adapter grezzo -> parsato

extension TicketSolution {
    init(raw: RawSolution) {
        let info = raw.solution
        let grids = raw.grids ?? []

        // Treni: prima dai summaries delle grids, altrimenti da solution.trains.
        var trains: [TicketTrain] = []
        for grid in grids {
            for s in grid.summaries ?? [] {
                guard let t = s.trainInfo, (t.acronym != nil || t.denomination != nil) else { continue }
                trains.append(TicketTrain(
                    label: TicketTrain.makeLabel(acronym: t.acronym, name: t.name, denomination: t.denomination),
                    departure: TicketSolution.hhmm(s.departureTime),
                    arrival: TicketSolution.hhmm(s.arrivalTime),
                    departureStation: s.departureLocationName ?? "",
                    arrivalStation: s.arrivalLocationName ?? "",
                    isTrenord: (t.denomination ?? "").uppercased().contains("TRENORD"),
                    logoImageName: TicketTrain.logo(acronym: t.acronym, denomination: t.denomination)))
            }
        }
        if trains.isEmpty {
            for t in info?.trains ?? [] {
                trains.append(TicketTrain(
                    label: TicketTrain.makeLabel(acronym: t.acronym, name: t.name, denomination: t.denomination),
                    departure: TicketSolution.hhmm(info?.departureTime),
                    arrival: TicketSolution.hhmm(info?.arrivalTime),
                    departureStation: info?.origin ?? "",
                    arrivalStation: info?.destination ?? "",
                    isTrenord: (t.denomination ?? "").uppercased().contains("TRENORD"),
                    logoImageName: TicketTrain.logo(acronym: t.acronym, denomination: t.denomination)))
            }
        }

        let direct = grids.count == 1 && (grids.first?.summaries?.count ?? 0) == 1
        let changes = direct ? 0 : max(0, trains.count - 1)

        // Servizi e offerte con prezzo.
        var services: [TicketService] = []
        for grid in grids {
            for svc in grid.services ?? [] {
                let offers = (svc.offers ?? []).compactMap { o -> TicketOffer? in
                    guard let amount = o.price?.amount else { return nil }
                    return TicketOffer(name: o.name ?? "", amount: amount,
                                       seats: o.availableAmount ?? 0, status: o.status ?? "",
                                       refundable: o.canRefund, changeable: o.canChange)
                }
                guard !offers.isEmpty else { continue }
                services.append(TicketService(group: svc.groupName ?? svc.shortName ?? svc.name ?? "", offers: offers))
            }
        }

        let amounts = services.flatMap { $0.offers.compactMap(\.amount) }
        let minPrice = amounts.min() ?? info?.price?.amount

        let messages = (raw.messages ?? []).compactMap { $0?.message }.filter { !$0.isEmpty }
        let co2 = raw.co2Emission?.summaryTitle?
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")

        self.init(
            id: info?.id ?? UUID().uuidString,
            origin: info?.origin ?? "",
            destination: info?.destination ?? "",
            departure: TicketSolution.hhmm(info?.departureTime),
            arrival: TicketSolution.hhmm(info?.arrivalTime),
            duration: info?.duration ?? "",
            status: info?.status ?? "UNKNOWN",
            direct: direct,
            changes: changes,
            trains: trains,
            services: services,
            minPrice: minPrice,
            messages: messages,
            co2: co2,
            durationMinutes: info?.duration.flatMap(TicketDuration.minutes)
        )
    }

    /// Estrae "HH:mm" da un orario ISO "2026-07-15T08:10:00.000+02:00".
    static func hhmm(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "--:--" }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[start..<end])
    }
}
