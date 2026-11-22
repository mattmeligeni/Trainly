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

/// Errore BIG, es. {"Code":1130,"Message":"Error : your app is obsolete…"}.
struct ItaloErrorResponse: Codable {
    let Code: Int?
    let Message: String?
}

// MARK: - Stazioni (api-biglietti.italotreno.com)

struct ItaloStationsResponse: Codable {
    let stations: [ItaloStation]?
}

struct ItaloStation: Codable {
    let stationCode: String?
    let name: String?
    let isItaloStation: Bool?
    var isMAC: Bool? = nil          // stazione cumulativa, es. "Milano (Tutte)"
    var stationClass: String? = nil // "T" treno, "B" bus
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
    var DepartureStation: String? = nil
    var ArrivalStation: String? = nil
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
    var PaxType: String? = nil      // "ADT" adulto, "CHD" ragazzo
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
    /// Costruisce una soluzione da una journey Italo vendibile (ogni segmento con
    /// Fares). Un segmento = treno diretto; più segmenti = cambi.
    init(italoJourney segments: [ItaloSegment], originName: String, destName: String,
         stationNames: [String: String], adults: Int, children: Int) {
        let first = segments.first
        let last = segments.last
        let std = ItaloDate.parse(first?.STD)
        let sta = ItaloDate.parse(last?.STA)
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

        // Nome della stazione di un segmento: estremi della ricerca, altrimenti
        // dal catalogo Italo (stazioni di cambio).
        func stationName(_ code: String?) -> String {
            code.flatMap { stationNames[$0] } ?? code ?? ""
        }
        let trains: [TicketTrain] = segments.enumerated().map { index, seg in
            let number = seg.TrainNumber ?? ""
            return TicketTrain(
                label: number.isEmpty ? "Italo" : "Italo \(number)",
                departure: ItaloDate.hhmmString(ItaloDate.parse(seg.STD)),
                arrival: ItaloDate.hhmmString(ItaloDate.parse(seg.STA)),
                departureStation: index == 0 ? originName : stationName(seg.DepartureStation),
                arrivalStation: index == segments.count - 1 ? destName : stationName(seg.ArrivalStation),
                isTrenord: false,
                logoImageName: "ITALO")
        }

        let services = segments.count == 1
            ? Self.italoServices(segments[0].Fares ?? [], adults: adults, children: children)
            : Self.italoConnectionServices(segments, trains: trains, adults: adults, children: children)

        let minPrice: Double?
        if segments.count > 1 {
            // Prezzi per tratta: il minimo è la somma dei minimi di ogni treno.
            let perTrain = segments.map { seg in
                Self.italoServices(seg.Fares ?? [], adults: adults, children: children)
                    .flatMap { $0.offers.compactMap(\.amount) }.min()
            }
            minPrice = perTrain.contains(where: { $0 == nil }) ? nil : perTrain.compactMap { $0 }.reduce(0, +)
        } else {
            minPrice = services.flatMap { $0.offers.compactMap(\.amount) }.min()
        }
        // Le journey che arrivano qui hanno tariffe con prezzo: sono vendibili.
        let status = minPrice != nil ? "SALEABLE" : "UNAVAILABLE"
        let numbers = segments.map { $0.TrainNumber ?? "" }.joined(separator: "+")

        self.init(
            id: first?.STD.map { "\(numbers)-\($0)" } ?? UUID().uuidString,
            origin: originName,
            destination: destName,
            departure: dep,
            arrival: arr,
            duration: durationText,
            status: status,
            direct: segments.count == 1,
            changes: segments.count - 1,
            trains: trains,
            services: services,
            minPrice: minPrice,
            messages: [],
            co2: nil,
            carrier: .italo,
            durationMinutes: minutes,
            passengers: max(1, adults) + max(0, children))
    }

    /// Servizi = classi di prodotto (Smart / Prima / Club), ognuna con le sue
    /// tariffe (offer type: Low Cost, Economy, Flex, …).
    private static func italoServices(_ fares: [ItaloFare], adults: Int, children: Int) -> [TicketService] {
        var grouped: [String: [ItaloFare]] = [:]
        var order: [String] = []
        for f in fares {
            let key = f.ProductClassName ?? f.ProductClass ?? "Tariffa"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(f)
        }
        return order.map { key in
            let offers = (grouped[key] ?? []).map { f -> TicketOffer in
                let (changeable, refundable, detail) = Self.italoPolicy(f.FarePolicy)
                return TicketOffer(
                    name: f.ClassOfServiceName ?? "",
                    amount: italoTotal(f.PaxFares, adults: adults, children: children),
                    seats: 0,                     // AvailableCount non è affidabile per gli ospiti
                    status: "",
                    refundable: refundable,
                    changeable: changeable,
                    detail: detail)
            }
            return TicketService(group: key, offers: offers)
        }
    }

    /// Con un cambio le tariffe sono per singolo treno: le mostriamo per tratta
    /// ("Italo 9915 · Smart"), senza inventare combinazioni.
    private static func italoConnectionServices(_ segments: [ItaloSegment], trains: [TicketTrain],
                                                adults: Int, children: Int) -> [TicketService] {
        zip(segments, trains).flatMap { seg, train in
            italoServices(seg.Fares ?? [], adults: adults, children: children).map {
                TicketService(group: "\(train.label) · \($0.group)", offers: $0.offers)
            }
        }
    }

    /// Prezzo totale della tariffa per tutti i passeggeri: PaxFares riporta il
    /// prezzo unitario per tipo di passeggero (ADT adulto, CHD ragazzo).
    private static func italoTotal(_ paxFares: [ItaloPaxFare]?, adults: Int, children: Int) -> Double? {
        guard let fares = paxFares, !fares.isEmpty else { return nil }
        func unit(_ f: ItaloPaxFare?) -> Double? { f?.DiscountedPaxFarePrice ?? f?.FullPaxFarePrice }
        let adultFare = fares.first { $0.PaxType == "ADT" } ?? fares.first
        guard let adult = unit(adultFare) else { return nil }
        let child = unit(fares.first { $0.PaxType == "CHD" }) ?? adult
        return adult * Double(max(1, adults)) + child * Double(max(0, children))
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
