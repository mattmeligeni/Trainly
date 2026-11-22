//
//  ItaloSeatMapService.swift
//  Trainly
//
//  Mappa dei posti Italo con l'API dell'app (api-app.italotreno.com), la stessa
//  usata dall'app ufficiale fino alla scelta del posto. Flusso:
//   1. users/logon (utente ospite)            -> token
//   2. POST booking + polling dello stato     -> soluzioni con disponibilità reale
//   3. per ogni classe disponibile:
//      PUT booking/{id}/journey/outbound      -> il treno nel carrello con quella tariffa
//      GET booking/{id}/seatmap/status        -> posti liberi per carrozza
//   4. GET seatmap -> SVG pubblici delle carrozze (posizione di ogni posto)
//  La mappa Italo esiste solo per un viaggio nel carrello: il passo 3 mette il
//  treno nel carrello come un utente che sceglie il posto, senza passeggeri né
//  pagamento. Il carrello non pagato scade da solo con la sessione.
//

import Foundation
import CoreGraphics

enum ItaloSeatMapService {

    private static let base = "https://api-app.italotreno.com"
    /// Identità client dell'app Android (quella iOS ha un'altra numerazione e con
    /// queste versioni risponde «app obsoleta»). Si prova in ordine se Italo alza
    /// la versione minima.
    private static let appVersions = ["5.1.3", "6.0.0", "9.9.9"]
    private static var appVersion = appVersions[0]

    // MARK: - Mappa completa

    /// Carrozze di tutte le classi del treno fra due fermate. `onProgress` riceve la
    /// mappa parziale dopo ogni classe caricata (caricate, totale).
    static func fullSeatMap(trainNumber: String, from: TrainStop, to: TrainStop,
                            onProgress: @MainActor (FullSeatMap, Int, Int) -> Void) async throws -> FullSeatMap {
        guard let departure = from.scheduledDeparture else { throw SeatMapError.stationNotSupported }
        let token = try await logon()

        async let originCode = stationCode(for: from.stationName)
        async let destinationCode = stationCode(for: to.stationName)
        guard let origin = await originCode, let destination = await destinationCode else {
            throw SeatMapError.stationNotSupported
        }

        let search = try await searchBooking(token: token, origin: origin, destination: destination, departure: departure)
        guard let bookingId = search.bookingId,
              let solution = (search.trips?.first?.travelSolutions ?? []).first(where: { sol in
                  let journeys = sol.journeys ?? []
                  return journeys.count == 1 && journeys.first?.segments?.first?.trainNumber == trainNumber
              }),
              let journey = solution.journeys?.first,
              let segment = journey.segments?.first else {
            throw SeatMapError.trainNotFound
        }

        // Una tariffa per classe (Club, Prima, Smart…), solo dove ci sono posti.
        var fareByClass: [String: ItaloAppFare] = [:]
        var allClasses: [String] = []
        for fare in segment.fares ?? [] {
            guard let pc = fare.productClass else { continue }
            if !allClasses.contains(pc) { allClasses.append(pc) }
            if (fare.availableCount ?? 0) > 0, fareByClass[pc] == nil { fareByClass[pc] = fare }
        }
        let classes = allClasses.filter { fareByClass[$0] != nil }
            .sorted { classOrder($0) < classOrder($1) }
        guard !classes.isEmpty else { throw SeatMapError.notSaleable("SOLD_OUT") }

        let svgURLs = (try? await seatMapSVGs(token: token)) ?? [:]
        let equipment = (segment.equipmentType ?? "").uppercased()

        var wagons: [String: ClassedWagon] = [:]
        var loaded = 0
        for pc in classes {
            try Task.checkCancellation()
            guard let fare = fareByClass[pc], let fareKey = fare.fareSellKey,
                  let journeyKey = journey.journeySellKey, let solutionId = solution.travelSolutionId else { continue }
            try await sell(token: token, bookingId: bookingId, solutionId: solutionId,
                           fareSellKey: fareKey, journeySellKey: journeyKey)
            let status = try await seatStatus(token: token, bookingId: bookingId)
            let compartments = status.segments?.first?.equipment?.availableCompartments ?? []
            for compartment in compartments {
                guard let name = compartment.compartmentName, wagons[name] == nil else { continue }
                let free = Set((compartment.availableSeats ?? []).compactMap(\.unit))
                if let wagon = await wagon(named: name, equipment: equipment, free: free, svgURLs: svgURLs) {
                    wagons[name] = ClassedWagon(wagon: wagon, className: className(pc))
                }
            }
            loaded += 1
            onProgress(merged(wagons, soldOut: [], allowed: true), loaded, classes.count)
        }

        // Carrozze senza posti liberi in nessuna classe: tutte occupate (o di una
        // classe esaurita). Le aggiungiamo per avere la composizione completa.
        for key in svgURLs.keys where key.hasPrefix("\(equipment)_C_") {
            let name = String(key.dropFirst("\(equipment)_C_".count))
            guard wagons[name] == nil,
                  let wagon = await wagon(named: name, equipment: equipment, free: [], svgURLs: svgURLs) else { continue }
            wagons[name] = ClassedWagon(wagon: wagon, className: "Completa")
        }

        let soldOut = allClasses.filter { fareByClass[$0] == nil }.map(className)
        return merged(wagons, soldOut: soldOut, allowed: true)
    }

    private static func merged(_ wagons: [String: ClassedWagon], soldOut: [String], allowed: Bool) -> FullSeatMap {
        let sorted = wagons.values.sorted {
            (Int($0.wagon.id) ?? .max, $0.wagon.id) < (Int($1.wagon.id) ?? .max, $1.wagon.id)
        }
        return FullSeatMap(wagons: sorted, soldOutClasses: soldOut, selectionAllowed: allowed)
    }

    private static func classOrder(_ pc: String) -> Int {
        switch pc { case "C": return 0; case "P": return 1; case "S": return 2; default: return 3 }
    }

    private static func className(_ pc: String) -> String {
        switch pc {
        case "C": return "Club Executive"
        case "P": return "Prima"
        case "S": return "Smart"
        case "S2": return "Smart Cinema"
        default: return pc
        }
    }

    // MARK: - Passi API

    private static func logon() async throws -> String {
        for version in appVersions {
            appVersion = version
            let body: [String: Any] = [
                "operatingSystem": "android", "username": "WWW_Anonymous", "password": "F3hoM!n0$!ZE",
                "versionNumber": version, "appName": "b2c"
            ]
            let (data, status) = try await raw("POST", "/public/api/v1/users/logon", body: body, token: nil)
            if status == 200, let token = (try? JSONDecoder().decode(ItaloAppLogon.self, from: data))?.token {
                return token
            }
            // 403 «app obsoleta»: si prova la versione successiva.
            guard status == 403 else { throw SeatMapError.network }
        }
        throw SeatMapError.network
    }

    private static func searchBooking(token: String, origin: String, destination: String,
                                      departure: Date) async throws -> ItaloAppSearch {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = rome
        let parts = calendar.dateComponents([.hour, .minute], from: departure)
        let minute = max(0, (parts.hour ?? 0) * 60 + (parts.minute ?? 0) - 1)
        let body: [String: Any] = [
            "isRoundTrip": false, "departureStation": origin, "arrivalStation": destination,
            "seniorPassengers": 0, "adultPassengers": 1, "youngPassengers": 0, "childPassengers": 0,
            "hasPet": false, "promoCode": NSNull(), "employeeOffer": NSNull(), "culture": "it-IT",
            "departureDate": dayFormatter.string(from: departure),
            "outboundTimeSlot": ["fromMinute": minute, "toMinute": 1439]
        ]
        let start = try await send("POST", "/api/v1/booking", body: body, token: token)
        guard let op = (try? JSONDecoder().decode(ItaloAppOperation.self, from: start))?.operationId else {
            throw SeatMapError.network
        }
        let result = try await poll("/api/v1/booking/status/\(op)", token: token)
        guard let search = try? JSONDecoder().decode(ItaloAppSearch.self, from: result) else { throw SeatMapError.network }
        return search
    }

    private static func sell(token: String, bookingId: String, solutionId: String,
                             fareSellKey: String, journeySellKey: String) async throws {
        let body: [String: Any] = [
            "travelSolutionId": solutionId,
            "journeySelections": [[
                "serviceProvider": "ITALO", "fareSellKey": fareSellKey, "journeySellKey": journeySellKey
            ]]
        ]
        let start = try await send("PUT", "/api/v1/booking/\(bookingId)/journey/outbound", body: body, token: token)
        guard let op = (try? JSONDecoder().decode(ItaloAppOperation.self, from: start))?.operationId else {
            throw SeatMapError.network
        }
        _ = try await poll("/api/v1/booking/\(bookingId)/journey/outbound/status/\(op)", token: token)
    }

    private static func seatStatus(token: String, bookingId: String) async throws -> ItaloAppSeatStatus {
        let data = try await send("GET", "/api/v1/booking/\(bookingId)/seatmap/status", body: nil, token: token)
        guard let status = try? JSONDecoder().decode(ItaloAppSeatStatus.self, from: data) else { throw SeatMapError.network }
        return status
    }

    private static func seatMapSVGs(token: String) async throws -> [String: String] {
        let data = try await send("GET", "/api/v1/seatmap", body: nil, token: token)
        return (try? JSONDecoder().decode(ItaloAppSeatMaps.self, from: data))?.seatMaps ?? [:]
    }

    /// Le operazioni lunghe rispondono 202 finché non sono pronte.
    private static func poll(_ path: String, token: String) async throws -> Data {
        for _ in 0..<60 {
            try Task.checkCancellation()
            let (data, status) = try await raw("GET", path, body: nil, token: token)
            if status == 200 { return data }
            guard status == 202 else { throw SeatMapError.network }
            let wait = (try? JSONDecoder().decode(ItaloAppOperation.self, from: data))?.retryAfter ?? 1000
            try await Task.sleep(nanoseconds: UInt64(max(300, min(wait, 3000))) * 1_000_000)
        }
        throw SeatMapError.network
    }

    // MARK: - Stazioni

    /// Codice stazione Italo dal nome mostrato dal tracking Italo, che non sempre
    /// coincide con l'anagrafica: «Mediopadana R.Emilia» = «Reggio Emilia AV»,
    /// «Napoli» = «Napoli Centrale», «Firenze Santa Maria Novella» = «Firenze S.M.Novella».
    static func stationCode(for name: String) async -> String? {
        let target = tokens(name)
        if target.contains("MEDIOPADANA") { return "AAV" }

        // Si cerca con le parole del nome finché l'autocomplete risponde.
        var candidates: [ItaloAppStation] = []
        let words = normalizedStationName(name).split(separator: " ").map(String.init)
        for word in words where word.count >= 3 {
            candidates = await searchStations(word)
            if !candidates.isEmpty { break }
        }
        candidates = candidates.filter { station in
            let n = (station.name ?? "").uppercased()
            return station.isItaloStation == true && station.stationCode != nil
                && !n.contains("TUTTE") && !n.contains("BUS")
        }
        if let exact = candidates.first(where: { tokens($0.name ?? "") == target }) { return exact.stationCode }

        func score(_ station: ItaloAppStation) -> Int {
            let t = tokens(station.name ?? "")
            var value = t.intersection(target).count * 2
            // Solo la città: è la stazione centrale.
            if target.count == 1, t.contains("CENTRALE") { value += 1 }
            return value
        }
        guard let best = candidates.max(by: { score($0) < score($1) }),
              Set(tokens(best.name ?? "")).intersection(target).count >= min(2, target.count) else { return nil }
        return best.stationCode
    }

    /// Parole normalizzate; San/Santa/Santo diventano «S» come nelle abbreviazioni.
    private static func tokens(_ name: String) -> Set<String> {
        Set(normalizedStationName(name).split(separator: " ").map { word -> String in
            ["SAN", "SANTA", "SANTO", "SANT"].contains(String(word)) ? "S" : String(word)
        })
    }

    private static func searchStations(_ query: String) async -> [ItaloAppStation] {
        guard var comps = URLComponents(string: "https://api-biglietti.italotreno.com/api/v1/stations") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "sn", value: query),
            URLQueryItem(name: "ps", value: "30"),
            URLQueryItem(name: "culture", value: "it-IT"),
            URLQueryItem(name: "onlyitalo", value: "true")
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return (try? JSONDecoder().decode(ItaloAppStations.self, from: data))?.stations ?? []
    }

    // MARK: - Carrozze (SVG)

    private static func wagon(named name: String, equipment: String, free: Set<String>,
                              svgURLs: [String: String]) async -> SeatWagon? {
        guard let urlString = svgURLs["\(equipment)_C_\(name)"], let url = URL(string: urlString),
              let layout = await ItaloSVGCache.shared.layout(url) else { return nil }
        let seats = layout.seats.map { seat in
            Seat(label: seat.number, number: seat.number,
                 image: SeatShape(id: nil, width: seat.frame.width, height: seat.frame.height,
                                  x: seat.frame.minX, y: seat.frame.minY, rotation: seat.rotation),
                 available: free.contains(seat.number))
        }
        let icons = layout.icons.map { icon in
            SeatShape(id: icon.kind, width: icon.frame.width, height: icon.frame.height,
                      x: icon.frame.minX, y: icon.frame.minY, rotation: nil)
        }
        return SeatWagon(id: name,
                         image: SeatShape(id: nil, width: layout.size.width, height: layout.size.height,
                                          x: nil, y: nil, rotation: nil),
                         available: !free.isEmpty, seats: seats, additionalIcons: icons)
    }

    // MARK: - HTTP

    private static let rome = TimeZone(identifier: "Europe/Rome")!

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func send(_ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> Data {
        let (data, status) = try await raw(method, path, body: body, token: token)
        guard (200...202).contains(status) else {
            throw (status == 400 || status == 404) ? SeatMapError.trainNotFound : SeatMapError.network
        }
        return data
    }

    private static func raw(_ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> (Data, Int) {
        guard let url = URL(string: base + path) else { throw SeatMapError.network }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("it-IT,it;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("italotreno-android-\(appVersion)", forHTTPHeaderField: "app-version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SeatMapError.network
        }
    }
}

// MARK: - Cache SVG (su disco: gli SVG delle carrozze non cambiano)

/// Scarica, conserva e legge gli SVG fuori dal main thread (ognuno pesa ~340 KB).
actor ItaloSVGCache {
    static let shared = ItaloSVGCache()
    private var layouts: [URL: ItaloWagonLayout] = [:]

    func layout(_ url: URL) async -> ItaloWagonLayout? {
        if let cached = layouts[url] { return cached }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("italo-seatmaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(url.lastPathComponent)

        var text: String?
        if let data = try? Data(contentsOf: file) {
            text = String(data: data, encoding: .utf8)
        } else if let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 {
            try? data.write(to: file, options: .atomic)
            text = String(data: data, encoding: .utf8)
        }
        guard let text, let layout = ItaloSVGParser.layout(svg: text) else { return nil }
        layouts[url] = layout
        return layout
    }
}

// MARK: - Lettura SVG

nonisolated struct ItaloWagonLayout: Sendable {
    struct SeatBox: Sendable { let number: String; let frame: CGRect; let rotation: Double }
    struct IconBox: Sendable { let kind: String; let frame: CGRect }
    let size: CGSize
    let seats: [SeatBox]
    let icons: [IconBox]
}

/// Estrae posti, tavoli e bagno dall'SVG di una carrozza Italo, per disegnarli
/// con lo stesso modello di Trenitalia (`SeatWagon`).
nonisolated enum ItaloSVGParser {
    static func layout(svg: String) -> ItaloWagonLayout? {
        guard let size = viewBox(svg) else { return nil }
        var seats: [ItaloWagonLayout.SeatBox] = []
        var icons: [ItaloWagonLayout.IconBox] = []

        // Ogni posto: <g class="seat-button" … id="56"> … <rect x y width height transform="rotate(±90 x y)">
        for match in matches(#"class="seat-button"[^>]*id="([A-Za-z0-9]+)""#, in: svg) {
            guard let number = match.groups.first,
                  let rect = firstRect(in: svg, after: match.end) else { continue }
            // Il rettangolo è la seduta; lo schienale sta dal lato opposto al verso
            // del posto: lo includiamo allungando il riquadro di metà altezza.
            var frame = rect.frame
            let back = frame.height * 0.5
            let rotation: Double
            if rect.rotation == 90 {          // schienale in basso: il posto guarda in alto
                frame.size.height += back
                rotation = 180
            } else if rect.rotation == -90 || rect.rotation == 270 {
                frame.origin.y -= back        // schienale in alto: il posto guarda in basso
                frame.size.height += back
                rotation = 0
            } else {
                rotation = 0
            }
            seats.append(.init(number: number, frame: frame, rotation: rotation))
        }

        // Tavoli e bagno come icone aggiuntive (id come quelli di lefrecce: 13 tavolo, 16 WC).
        for match in matches(#"<g id="(Tavolo[^"]*|bathroom[^"]*)""#, in: svg) {
            guard let name = match.groups.first, let rect = firstRect(in: svg, after: match.end) else { continue }
            icons.append(.init(kind: name.hasPrefix("Tavolo") ? "13" : "16", frame: rect.frame))
        }

        return seats.isEmpty ? nil : ItaloWagonLayout(size: size, seats: seats, icons: icons)
    }

    private static func viewBox(_ svg: String) -> CGSize? {
        guard let m = matches(#"viewBox="[\d.\-]+ [\d.\-]+ ([\d.]+) ([\d.]+)""#, in: svg).first,
              m.groups.count == 2, let w = Double(m.groups[0]), let h = Double(m.groups[1]), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    private struct Rect { let frame: CGRect; let rotation: Double }

    /// Primo <rect> dopo la posizione indicata (entro 1200 caratteri), con la
    /// rotazione applicata al riquadro.
    private static func firstRect(in svg: String, after offset: Int) -> Rect? {
        let ns = svg as NSString
        guard offset < ns.length else { return nil }
        let window = NSRange(location: offset, length: min(1200, ns.length - offset))
        guard let regex = try? NSRegularExpression(pattern: #"<rect ([^>]*)/?>"#),
              let m = regex.firstMatch(in: svg, range: window) else { return nil }
        let attrs = attributes(ns.substring(with: m.range(at: 1)))
        guard let x = attrs["x"].flatMap(Double.init), let y = attrs["y"].flatMap(Double.init),
              let w = attrs["width"].flatMap(Double.init), let h = attrs["height"].flatMap(Double.init) else { return nil }
        var rotation = 0.0
        if let t = attrs["transform"], let r = matches(#"rotate\(([-\d.]+)"#, in: t).first?.groups.first {
            rotation = Double(r) ?? 0
        }
        // rotate(±90) attorno a (x, y): il riquadro ruotato scambia i lati e si sposta.
        let frame: CGRect
        switch rotation {
        case 90: frame = CGRect(x: x - h, y: y, width: h, height: w)
        case -90, 270: frame = CGRect(x: x, y: y - w, width: h, height: w)
        default: frame = CGRect(x: x, y: y, width: w, height: h)
        }
        return Rect(frame: frame, rotation: rotation)
    }

    /// Attributi del tag; il confine evita che `stroke-width` diventi `width`.
    private static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for m in matches(#"(?<![\w-])([\w-]+)="([^"]*)""#, in: tag) where m.groups.count == 2 {
            result[m.groups[0]] = m.groups[1]
        }
        return result
    }

    private struct Match { let end: Int; let groups: [String] }

    private static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let groups = (1..<m.numberOfRanges).compactMap { i -> String? in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            return Match(end: m.range.location + m.range.length, groups: groups)
        }
    }
}

// MARK: - Modelli API app Italo (solo i campi usati)

struct ItaloAppLogon: Decodable { let token: String? }

struct ItaloAppOperation: Decodable {
    let operationId: String?
    let retryAfter: Int?
}

struct ItaloAppSearch: Decodable {
    let bookingId: String?
    let trips: [ItaloAppTrip]?
}

struct ItaloAppTrip: Decodable {
    let travelSolutions: [ItaloAppSolution]?
}

struct ItaloAppSolution: Decodable {
    let travelSolutionId: String?
    let journeys: [ItaloAppJourney]?
}

struct ItaloAppJourney: Decodable {
    let journeySellKey: String?
    let segments: [ItaloAppSegment]?
}

struct ItaloAppSegment: Decodable {
    let trainNumber: String?
    let equipmentType: String?
    let fares: [ItaloAppFare]?
}

struct ItaloAppFare: Decodable {
    let fareSellKey: String?
    let productClass: String?
    let availableCount: Int?
}

struct ItaloAppSeatStatus: Decodable {
    let segments: [ItaloAppSeatSegment]?
}

struct ItaloAppSeatSegment: Decodable {
    let equipment: ItaloAppEquipment?
}

struct ItaloAppEquipment: Decodable {
    let availableCompartments: [ItaloAppCompartment]?
}

struct ItaloAppCompartment: Decodable {
    let compartmentName: String?
    let availableSeats: [ItaloAppSeat]?
}

struct ItaloAppSeat: Decodable {
    let unit: String?
}

struct ItaloAppSeatMaps: Decodable {
    let seatMaps: [String: String]?
}

struct ItaloAppStations: Decodable {
    let stations: [ItaloAppStation]?
}

struct ItaloAppStation: Decodable {
    let stationCode: String?
    let name: String?
    let isItaloStation: Bool?
}
