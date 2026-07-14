//
//  TrainJourney.swift
//  Trainly
//
//  Modello normalizzato usato dalla UI (TrainView).
//  I vari vettori (Trenitalia, Italo, Trenord) hanno strutture diverse:
//  qui li riportiamo a un formato comune così la view resta unica.
//

import Foundation

// MARK: - Modello percorso

struct TrainJourney: Hashable {
    let trainNumber: String
    let title: String              // es. "Trenitalia Frecciarossa 8509", "ITALO Av 9018"
    let category: String?          // es. "FRECCIAROSSA" -> nome imageset in Assets
    let origin: String
    let destination: String
    let delayMinutes: Int
    let lastDetectionStation: String?   // solo Trenitalia (posizione in tempo reale)
    let lastDetectionTime: Date?
    var notice: String? = nil           // avviso cancellazione/modifica (rosso)
    let stops: [TrainStop]

    /// Prossima fermata da effettuare (la prima non ancora passata).
    var nextStop: TrainStop? {
        stops.first { !$0.isPassed }
    }

    /// Orario di partenza dall'origine (per distinguere corse con lo stesso numero).
    var departure: Date? {
        stops.first?.scheduledDeparture ?? stops.first?.actualDeparture
    }

    /// True se il vettore fornisce la posizione in tempo reale (Trenitalia).
    var hasLivePosition: Bool { lastDetectionStation != nil }

    var isOnTime: Bool { delayMinutes <= 0 }
}

struct TrainStop: Identifiable, Hashable {
    let id = UUID()
    let stationName: String
    let scheduledArrival: Date?
    let actualArrival: Date?
    let scheduledDeparture: Date?
    let actualDeparture: Date?
    var estimatedArrival: Date? = nil    // previsto (programmato + ritardo) per fermate future
    var estimatedDeparture: Date? = nil
    let platform: String?          // binario
    let platformConfirmed: Bool    // true = effettivo (confermato), false = programmato (previsto)
    let isPassed: Bool             // fermata già effettuata
    var orientation: String? = nil // es. "Executive in coda" / "Executive in testa"
    var isExtraordinary = false    // fermata straordinaria (percorso deviato)

    var isFirst = false
    var isLast = false

    /// Ritardo in minuti sulla fermata, calcolato su arrivo o partenza.
    var delayMinutes: Int? {
        if let sched = scheduledArrival, let act = actualArrival {
            return Int(act.timeIntervalSince(sched) / 60)
        }
        if let sched = scheduledDeparture, let act = actualDeparture {
            return Int(act.timeIntervalSince(sched) / 60)
        }
        return nil
    }
}

// MARK: - Adapter Trenitalia

extension TrainJourney {

    /// Costruisce un percorso normalizzato dalla risposta Trenitalia.
    init(trenitalia r: TrenitaliaResponse, now: Date = Date()) {
        let raw = r.fermate ?? []
        let stops: [TrainStop] = raw.enumerated().map { index, f in
            let isFirst = index == 0
            let isLast = index == raw.count - 1

            // Orari separati arrivo/partenza. Il capolinea di partenza non ha
            // arrivo (arrivo_teorico == nil), quello di arrivo non ha partenza.
            let scheduledArrival = TrainJourney.date(fromMillis: f.arrivo_teorico)
            let actualArrival = TrainJourney.date(fromMillis: f.arrivoReale)
            let scheduledDeparture = TrainJourney.date(fromMillis: f.partenza_teorica)
            let actualDeparture = TrainJourney.date(fromMillis: f.partenzaReale)

            // Previsto = programmato + ritardo attuale del treno (per le fermate future).
            let delaySeconds = TimeInterval((r.ritardo ?? 0) * 60)
            let estimatedArrival = scheduledArrival?.addingTimeInterval(delaySeconds)
            let estimatedDeparture = scheduledDeparture?.addingTimeInterval(delaySeconds)

            // Binario: preferiamo l'effettivo (confermato), altrimenti il programmato.
            let effPlatform = f.binarioEffettivoPartenzaDescrizione ?? f.binarioEffettivoArrivoDescrizione
            let progPlatform = f.binarioProgrammatoPartenzaDescrizione ?? f.binarioProgrammatoArrivoDescrizione
            let confirmed = effPlatform != nil
            let platform = effPlatform ?? progPlatform

            // Fermata effettuata se ha già una partenza/arrivo reale nel passato.
            let lastActual = actualDeparture ?? actualArrival
            let passed = (lastActual.map { $0 <= now }) ?? false

            return TrainStop(
                stationName: (f.stazione ?? "").capitalized,
                scheduledArrival: scheduledArrival,
                actualArrival: actualArrival,
                scheduledDeparture: scheduledDeparture,
                actualDeparture: actualDeparture,
                estimatedArrival: estimatedArrival,
                estimatedDeparture: estimatedDeparture,
                platform: platform,
                platformConfirmed: confirmed,
                isPassed: passed,
                orientation: TrainJourney.orientationLabel(
                    desc: r.compOrientamento ?? r.descOrientamento ?? [],
                    orientamento: f.orientamento),
                isExtraordinary: f.actualFermataType == 2,
                isFirst: isFirst,
                isLast: isLast
            )
        }

        let numero = r.numeroTreno.map(String.init) ?? ""
        let origin = (r.origine ?? "").capitalized
        let destination = (r.destinazione ?? "").capitalized

        // Leonardo Express: collega Roma Termini e Fiumicino Aeroporto senza
        // fermate intermedie (a differenza dei regionali FL1 con molte fermate).
        let endpoints = "\(origin) \(destination)".uppercased()
        let isLeonardo = stops.count <= 2 && endpoints.contains("FIUMICINO")

        let category: String?
        let type: String?
        if isLeonardo {
            category = "LEONARDOEXP"
            type = "Leonardo Express"
        } else {
            category = TrainJourney.category(fromCompNumero: r.compNumeroTreno)
            type = TrainJourney.trenitaliaType(fromCompNumero: r.compNumeroTreno)
        }

        let title = ["Trenitalia", type, numero.isEmpty ? nil : numero]
            .compactMap { $0 }
            .joined(separator: " ")

        self.init(
            trainNumber: numero,
            title: title,
            category: category,
            origin: origin,
            destination: destination,
            delayMinutes: r.ritardo ?? 0,
            lastDetectionStation: r.stazioneUltimoRilevamento?.capitalized,
            lastDetectionTime: TrainJourney.date(fromMillis: r.oraUltimoRilevamento),
            notice: TrainJourney.disruptionNotice(r.subTitle),
            stops: stops
        )
    }

    /// Il subTitle viene popolato solo per avvisi (cancellazioni, deviazioni,
    /// fermate straordinarie…): se c'è, lo mostriamo sempre.
    private static func disruptionNotice(_ subTitle: String?) -> String? {
        let s = subTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Ricava il nome dell'imageset dal prefisso di `compNumeroTreno` (es. " FR 8509").
    private static func category(fromCompNumero comp: String?) -> String? {
        guard let comp = comp?.trimmingCharacters(in: .whitespaces), !comp.isEmpty else { return nil }
        let prefix = (comp.split(separator: " ").first.map(String.init) ?? comp).uppercased()
        switch prefix {
        case "FR": return "FRECCIAROSSA"
        case "FA": return "FRECCIARGENTO"
        case "FB": return "FRECCIABIANCA"
        case "IC", "ICN": return "INTERCITY-2"
        case "REG", "RV", "R": return "TRENITALIA-3"
        default: return "TRENITALIA"
        }
    }

    /// Nome leggibile del tipo treno per il titolo, dal prefisso di `compNumeroTreno`.
    private static func trenitaliaType(fromCompNumero comp: String?) -> String? {
        guard let comp = comp?.trimmingCharacters(in: .whitespaces), !comp.isEmpty else { return nil }
        let prefix = (comp.split(separator: " ").first.map(String.init) ?? comp).uppercased()
        switch prefix {
        case "FR": return "Frecciarossa"
        case "FA": return "Frecciargento"
        case "FB": return "Frecciabianca"
        case "IC", "ICN": return "Intercity"
        case "REG", "RV", "R": return "Regionale"
        default: return nil
        }
    }

    /// Orientamento della carrozza mostrato su ogni fermata.
    /// `compOrientamento[0]` descrive la posizione per orientamento "A"
    /// (es. "Executive in coda"); per "B" viene invertita coda/testa.
    /// Restituisce nil se manca la composizione (placeholder "--") o l'orientamento.
    private static func orientationLabel(desc: [String], orientamento: String?) -> String? {
        guard let orientamento, let base = desc.first else { return nil }

        let hasCoda = base.range(of: "coda", options: .caseInsensitive) != nil
        let hasTesta = base.range(of: "testa", options: .caseInsensitive) != nil
        // Nessuna posizione reale (es. "--", "---") -> non mostriamo nulla.
        guard hasCoda || hasTesta else { return nil }

        var label = base
        if let r = base.range(of: "in coda", options: .caseInsensitive)
            ?? base.range(of: "in testa", options: .caseInsensitive) {
            label = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let isCoda = orientamento.uppercased() == "A" ? hasCoda : !hasCoda
        let position = isCoda ? "in coda" : "in testa"
        return label.isEmpty ? position.capitalized : "\(label) \(position)"
    }

    private static func date(fromMillis millis: Int?) -> Date? {
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}

// MARK: - Adapter Italo

extension TrainJourney {

    /// Costruisce un percorso normalizzato dalla risposta Italo.
    /// Restituisce nil se la risposta è vuota (treno non in circolazione).
    init?(italo r: ItaloResponse) {
        guard r.isEmpty != true, let s = r.trainSchedule else { return nil }

        // Le fermate già effettuate stanno in StazioniFerme, quelle da fare in
        // StazioniNonFerme; le uniamo ordinando per StationNumber.
        let done = (s.stazioniFerme ?? []).map { ($0, true) }
        let todo = (s.stazioniNonFerme ?? []).map { ($0, false) }
        let intermediate = (done + todo).sorted { ($0.0.stationNumber ?? 0) < ($1.0.stationNumber ?? 0) }

        let delaySeconds = TimeInterval((s.distruption?.delayAmount ?? 0) * 60)

        // La stazione di origine non è nelle liste: la ricostruiamo a parte.
        let originPassed = !(s.stazioniFerme ?? []).isEmpty
        let originSched = TrainJourney.time(s.departureDate)
        let origin = TrainStop(
            stationName: s.departureStationDescription ?? "",
            scheduledArrival: nil,
            actualArrival: nil,
            scheduledDeparture: originSched,
            actualDeparture: nil,
            estimatedDeparture: originSched?.addingTimeInterval(delaySeconds),
            platform: nil,
            platformConfirmed: false,
            isPassed: originPassed,
            isFirst: true,
            isLast: false
        )

        var stops: [TrainStop] = [origin]
        for (offset, item) in intermediate.enumerated() {
            let (st, passed) = item
            let isLast = offset == intermediate.count - 1

            // Programmato (timetable) + previsto (programmato + ritardo).
            let schedArr = TrainJourney.time(st.estimatedArrivalTime)
            // Il capolinea ha orari di partenza fittizi ("01:00"): li sopprimiamo.
            let schedDep = isLast ? nil : TrainJourney.time(st.estimatedDepartureTime)

            let platform = st.actualArrivalPlatform
            stops.append(TrainStop(
                stationName: st.locationDescription ?? "",
                scheduledArrival: schedArr,
                // Orario reale solo a fermata effettuata.
                actualArrival: passed ? TrainJourney.time(st.actualArrivalTime) : nil,
                scheduledDeparture: schedDep,
                actualDeparture: (passed && !isLast) ? TrainJourney.time(st.actualDepartureTime) : nil,
                estimatedArrival: schedArr?.addingTimeInterval(delaySeconds),
                estimatedDeparture: schedDep?.addingTimeInterval(delaySeconds),
                platform: platform,
                platformConfirmed: platform != nil,
                isPassed: passed,
                isFirst: false,
                isLast: isLast
            ))
        }

        let numero = s.trainNumber ?? ""
        self.init(
            trainNumber: numero,
            title: numero.isEmpty ? "ITALO" : "ITALO Av \(numero)",
            category: "ITALO",
            origin: s.departureStationDescription ?? "",
            destination: s.arrivalStationDescription ?? "",
            delayMinutes: s.distruption?.delayAmount ?? 0,
            lastDetectionStation: nil,
            lastDetectionTime: nil,
            stops: stops
        )
    }
}

// MARK: - Adapter Trenord

extension TrainJourney {

    /// Costruisce un percorso normalizzato dalla prima soluzione Trenord.
    init?(trenord response: TrenordResponse) {
        guard let solution = response.first else { return nil }
        let journeys = solution.journeyList ?? []
        let passes = journeys.flatMap { $0.passList ?? [] }

        // solution.delay è spesso 0 anche se il treno è in ritardo: ricaviamo il
        // ritardo attuale dall'ultima fermata effettuata (orario reale vs programmato).
        var delaySeconds: TimeInterval = 0
        for p in passes {
            let a = p.actualData
            if let real = TrainJourney.time(a?.depActualTime), let sched = TrainJourney.time(p.depTime) {
                delaySeconds = real.timeIntervalSince(sched)
            } else if let real = TrainJourney.time(a?.arrActualTime), let sched = TrainJourney.time(p.arrTime) {
                delaySeconds = real.timeIntervalSince(sched)
            }
        }

        let stops: [TrainStop] = passes.enumerated().map { index, p in
            let isFirst = index == 0
            let isLast = index == passes.count - 1

            let actual = p.actualData
            // Trenord fornisce direttamente binario + flag "reale".
            let confirmed = (p.isActualPlatform ?? false) && p.platform != nil

            let schedArr = TrainJourney.time(p.arrTime)
            let schedDep = TrainJourney.time(p.depTime)

            return TrainStop(
                stationName: (p.station?.stationOriName ?? "").capitalized,
                scheduledArrival: schedArr,
                // Solo l'orario effettivo; il previsto lo calcoliamo noi (uniforme).
                actualArrival: TrainJourney.time(actual?.arrActualTime),
                scheduledDeparture: schedDep,
                actualDeparture: TrainJourney.time(actual?.depActualTime),
                estimatedArrival: schedArr?.addingTimeInterval(delaySeconds),
                estimatedDeparture: schedDep?.addingTimeInterval(delaySeconds),
                platform: p.platform,
                platformConfirmed: confirmed,
                isPassed: actual?.depActualTime != nil || actual?.arrActualTime != nil,
                isFirst: isFirst,
                isLast: isLast
            )
        }

        let train = journeys.first?.train
        let number = train?.trainId ?? train?.trainName ?? ""

        self.init(
            trainNumber: number,
            title: number.isEmpty ? "Trenord" : "Trenord \(number)",
            category: "TRENORD-2",
            origin: (solution.depStation?.stationOriName ?? "").capitalized,
            destination: (solution.arrStation?.stationOriName ?? "").capitalized,
            delayMinutes: Int(delaySeconds / 60),
            lastDetectionStation: nil,
            lastDetectionTime: nil,
            stops: stops
        )
    }
}

// MARK: - Helper orari

extension TrainJourney {

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let hmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Converte orari stringa "HH:mm" o "HH:mm:ss" in Date (odierna).
    /// Restituisce nil per stringhe vuote o nil (fermata senza quell'orario).
    static func time(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return hmFormatter.date(from: value) ?? hmsFormatter.date(from: value)
    }
}
