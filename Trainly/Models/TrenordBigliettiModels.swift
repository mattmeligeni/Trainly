//
//  TrenordBigliettiModels.swift
//  Trainly
//
//  Ricerca soluzioni Trenord (cloud.mp.trenord.it/hafas/v2). L'endpoint restituisce
//  5 soluzioni per chiamata; la pagina successiva si ottiene ripartendo dall'orario
//  dell'ultima soluzione + 1 minuto.
//

import Foundation

// MARK: - Risposta grezza (solo i campi usati)

struct TrenordSolutionsResponse: Codable {
    let solutions: [TrenordRawSolution]?
}

struct TrenordRawSolution: Codable {
    let dep_time: String?
    let arr_time: String?
    let duration: String?
    let change: String?
    let saleability: TrenordSaleability?
    let journey_list: [TrenordRawJourney]?
    let products: [TrenordRawProduct]?
}

struct TrenordSaleability: Codable {
    let status: Bool?
}

struct TrenordRawJourney: Codable {
    let train: TrenordRawTrain?
    let pass_list: [TrenordRawStop]?
}

struct TrenordRawTrain: Codable {
    let train_category: String?
    let train_name: String?
    let train_operator: String?
    let bicycle: Bool?
    let handicap: Bool?
    let class_1: Bool?
    let class_2: Bool?
    let delay: Int?
    let average_crowding: Int?
    let average_crowding_label: String?
}

struct TrenordRawStop: Codable {
    let dep_time: String?
    let arr_time: String?
    let station: TrenordRawStopStation?
}

struct TrenordRawStopStation: Codable {
    let station_ori_name: String?
}

struct TrenordRawProduct: Codable {
    let name: String?
    let localized_name: String?
    let description: String?
    let localized_description: String?
    let tariff_type: String?
    let price: Double?
}

// MARK: - Helpers orario

enum TrenordTime {
    /// "08:37:00" -> "08:37".
    static func hhmm(_ raw: String?) -> String {
        guard let raw, raw.count >= 5 else { return "--:--" }
        return String(raw.prefix(5))
    }

    /// "01:05:00" -> "1h 05m", "00:35:00" -> "35m".
    static func durationText(_ raw: String?) -> String {
        guard let raw else { return "" }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return "" }
        let (h, m) = (parts[0], parts[1])
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// "01:05:00" -> 65 minuti.
    static func minutes(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// "08:47" -> "08:48" (orario di partenza della pagina successiva).
    static func nextMinute(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return hhmm }
        var (h, m) = (parts[0], parts[1])
        m += 1
        if m >= 60 { m = 0; h += 1 }
        if h >= 24 { h = 23; m = 59 }
        return String(format: "%02d:%02d", h, m)
    }
}

// MARK: - Adapter Trenord -> TicketSolution

extension TicketSolution {
    init(trenordSolution sol: TrenordRawSolution, originName: String, destName: String) {
        let dep = TrenordTime.hhmm(sol.dep_time)
        let arr = TrenordTime.hhmm(sol.arr_time)
        let changes = sol.change.flatMap { Int($0) } ?? max(0, (sol.journey_list?.count ?? 1) - 1)

        // Treni della soluzione, con stazioni prese dalla pass_list.
        let trains: [TicketTrain] = (sol.journey_list ?? []).map { j -> TicketTrain in
            let t = j.train
            let category = t?.train_category ?? ""
            let number = t?.train_name ?? ""
            let label = "\(category) \(number)".trimmingCharacters(in: .whitespaces)
            let stops = j.pass_list ?? []
            let first = stops.first
            let last = stops.last
            return TicketTrain(
                label: label.isEmpty ? "Trenord" : label,
                departure: TrenordTime.hhmm(first?.dep_time ?? first?.arr_time),
                arrival: TrenordTime.hhmm(last?.arr_time ?? last?.dep_time),
                departureStation: first?.station?.station_ori_name ?? originName,
                arrivalStation: last?.station?.station_ori_name ?? destName,
                isTrenord: true,
                logoImageName: "TRENORD-2",
                bikeAllowed: t?.bicycle,
                accessible: t?.handicap,
                secondClassOnly: (t?.class_1 == false && t?.class_2 == true) ? true : nil,
                crowdingPercent: (t?.average_crowding).flatMap { $0 > 0 ? $0 : nil },
                crowdingLabel: t?.average_crowding_label,
                delayMinutes: (t?.delay).flatMap { $0 > 0 ? $0 : nil })
        }

        // Servizi = prodotti tariffari (Corsa Singola, …), con le varianti per
        // tipo di passeggero (adulto/ragazzo/anziano).
        var grouped: [String: [TrenordRawProduct]] = [:]
        var order: [String] = []
        for p in sol.products ?? [] {
            let key = p.localized_name ?? p.name ?? "Tariffa"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(p)
        }
        let services: [TicketService] = order.map { key in
            let offers = (grouped[key] ?? []).map { p -> TicketOffer in
                let variant = p.tariff_type ?? p.localized_description ?? p.description ?? ""
                // Trenord non espone modificabilità/rimborso -> nessuna icona.
                return TicketOffer(name: variant.capitalized, amount: p.price,
                                   seats: 0, status: "", refundable: nil, changeable: nil)
            }
            return TicketService(group: key, offers: offers)
        }

        let amounts = (sol.products ?? []).compactMap { $0.price }
        let minPrice = amounts.min()
        let status = (sol.saleability?.status == true) ? "SALEABLE" : "UNAVAILABLE"

        self.init(
            id: "TN-\(dep)-\(arr)-\(trains.first?.label ?? "")",
            origin: originName,
            destination: destName,
            departure: dep,
            arrival: arr,
            duration: TrenordTime.durationText(sol.duration),
            status: status,
            direct: changes == 0,
            changes: changes,
            trains: trains,
            services: services,
            minPrice: minPrice,
            messages: [],
            co2: nil,
            carrier: .trenord,
            durationMinutes: TrenordTime.minutes(sol.duration))
    }
}
