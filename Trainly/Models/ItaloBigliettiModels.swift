//
//  ItaloBigliettiModels.swift
//  Trainly
//
//  Ricerca biglietti Italo (big.ntvspa.it BIG). Login anonimo -> GetAvailableTrains.
//  Le risposte contengono moltissimi campi: qui decodifichiamo solo il necessario.
//

import Foundation

// MARK: - Login

struct ItaloLoginResponse: Codable {
    let Signature: String?
}

// MARK: - Stazioni (api-biglietti.italotreno.com)

struct ItaloStationsResponse: Codable {
    let stations: [ItaloStation]?
}

struct ItaloStation: Codable {
    let stationCode: String?
    let name: String?
    let isItaloStation: Bool?
}

// MARK: - GetAvailableTrains (solo i campi usati)

struct ItaloTrainsResponse: Codable {
    let JourneyDateMarkets: [ItaloMarket]?
}

struct ItaloMarket: Codable {
    let DepartureStation: String?
    let ArrivalStation: String?
    let Journeys: [ItaloJourney]?
}

struct ItaloJourney: Codable {
    let Capacity: Int?
    let Segments: [ItaloSegment]?
}

struct ItaloSegment: Codable {
    let TrainNumber: String?
    let STD: String?
    let STA: String?
    let NoStopTrain: Bool?
    let OneStopTrain: Bool?
    let Legs: [ItaloLeg]?
    let Fares: [ItaloFare]?
}

struct ItaloLeg: Codable {
    let DepartureStation: String?
    let ArrivalStation: String?
    let STD: String?
    let STA: String?
}

struct ItaloFare: Codable {
    let ProductClass: String?
    let ProductClassName: String?
    let ClassOfServiceName: String?
    let AvailableCount: Int?
    let PaxFares: [ItaloPaxFare]?
    let FarePolicy: ItaloFarePolicy?
}

struct ItaloFarePolicy: Codable {
    let RefundFee: String?
    let ChangeFee: String?
}

struct ItaloPaxFare: Codable {
    let FullPaxFarePrice: Double?
    let DiscountedPaxFarePrice: Double?
}

// MARK: - Parsing date /Date(ms+0000)/

enum ItaloDate {
    /// "/Date(1784346000000+0200)/" -> Date (istante assoluto).
    static func parse(_ raw: String?) -> Date? {
        guard let raw, let range = raw.range(of: #"\d+"#, options: .regularExpression),
              let ms = Double(raw[range]) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func hhmmString(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return hhmm.string(from: date)
    }
}

// MARK: - Adapter Italo -> TicketSolution

extension TicketSolution {
    /// Costruisce una soluzione a partire da un segmento Italo vendibile (con Fares).
    /// Ogni segmento è un singolo treno Italo (nessun cambio), quindi `direct`.
    init(italoSegment seg: ItaloSegment, originName: String, destName: String) {
        let std = ItaloDate.parse(seg.STD)
        let sta = ItaloDate.parse(seg.STA)
        let dep = ItaloDate.hhmmString(std)
        let arr = ItaloDate.hhmmString(sta)

        var minutes: Int?
        let durationText: String
        if let std, let sta {
            let mins = Int(sta.timeIntervalSince(std) / 60)
            minutes = mins
            durationText = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
        } else {
            durationText = ""
        }

        let number = seg.TrainNumber ?? ""
        let train = TicketTrain(
            label: number.isEmpty ? "Italo" : "Italo \(number)",
            departure: dep,
            arrival: arr,
            departureStation: originName,
            arrivalStation: destName,
            isTrenord: false,
            logoImageName: "ITALO")

        // Servizi = classi di prodotto (Smart / Prima / Club), ognuna con le sue
        // tariffe (offer type: Low Cost, Economy, Flex, …).
        let fares = seg.Fares ?? []
        var grouped: [String: [ItaloFare]] = [:]
        var order: [String] = []
        for f in fares {
            let key = f.ProductClassName ?? f.ProductClass ?? "Tariffa"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(f)
        }
        let services: [TicketService] = order.map { key in
            let offers = (grouped[key] ?? []).map { f -> TicketOffer in
                let pax = f.PaxFares?.first
                let amount = pax?.DiscountedPaxFarePrice ?? pax?.FullPaxFarePrice
                let (changeable, refundable, detail) = Self.italoPolicy(f.FarePolicy)
                return TicketOffer(
                    name: f.ClassOfServiceName ?? "",
                    amount: amount,
                    seats: 0,                     // AvailableCount non è affidabile per gli ospiti
                    status: "",
                    refundable: refundable,
                    changeable: changeable,
                    detail: detail)
            }
            return TicketService(group: key, offers: offers)
        }

        let amounts = services.flatMap { $0.offers.compactMap(\.amount) }
        let minPrice = amounts.min()
        // I segmenti che arrivano qui hanno tariffe con prezzo: sono vendibili.
        let status = minPrice != nil ? "SALEABLE" : "UNAVAILABLE"

        self.init(
            id: seg.STD.map { "\(number)-\($0)" } ?? UUID().uuidString,
            origin: originName,
            destination: destName,
            departure: dep,
            arrival: arr,
            duration: durationText,
            status: status,
            direct: true,
            changes: 0,
            trains: [train],
            services: services,
            minPrice: minPrice,
            messages: [],
            co2: nil,
            carrier: .italo,
            durationMinutes: minutes)
    }

    /// Interpreta la FarePolicy Italo -> (modificabile?, rimborsabile?, testo).
    /// "0" = gratis, "100%" = di fatto non consentito, assente = informazione non nota.
    private static func italoPolicy(_ policy: ItaloFarePolicy?) -> (Bool?, Bool?, String?) {
        guard let policy else { return (nil, nil, nil) }
        var changeable: Bool?
        var refundable: Bool?
        var parts: [String] = []

        if let change = policy.ChangeFee?.trimmingCharacters(in: .whitespaces), !change.isEmpty {
            let free = (change == "0" || change == "0%")
            changeable = change != "100%"
            if changeable == true { parts.append(free ? "Cambio gratuito" : "Cambio \(change)") }
        }
        if let refund = policy.RefundFee?.trimmingCharacters(in: .whitespaces), !refund.isEmpty {
            refundable = refund != "100%"
            if refundable == true { parts.append("Rimborso con trattenuta \(refund)") }
        }
        return (changeable, refundable, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// Istante di partenza del segmento (per filtro/ordinamento).
    static func italoDeparture(of seg: ItaloSegment) -> Date? { ItaloDate.parse(seg.STD) }
}
