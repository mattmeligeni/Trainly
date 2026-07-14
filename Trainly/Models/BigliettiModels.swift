//
//  BigliettiModels.swift
//  Trainly
//
//  Ricerca biglietti Trenitalia (lefrecce BFF). Vedi Test/trenitalia.py.
//

import Foundation

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

    var isSaleable: Bool { status == "SALEABLE" }
    var hasTrenord: Bool { trains.contains(where: \.isTrenord) }
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
    let refundable: Bool
    let changeable: Bool
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
                                       refundable: o.canRefund ?? false, changeable: o.canChange ?? false)
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
            co2: co2
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
