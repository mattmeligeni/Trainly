//
//  TrainView.swift
//  Trainly
//
//  Mostra il percorso attuale del treno: info in alto e timeline
//  verticale a step con le fermate effettuate e da effettuare.
//

internal import SwiftUI

struct TrainView: View {

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var journey: TrainJourney

    /// Descrittore per i preferiti; nil = pulsante stella nascosto (es. preview).
    private let favorite: FavoriteTrain?

    /// Ricarica i dati (pull-to-refresh e aggiornamento automatico); nil = nessun reload.
    /// Lancia l'errore: serve a dire all'utente perché l'aggiornamento non è riuscito.
    private let reload: (() async throws -> TrainJourney)?

    /// Stesse corse su più giorni (picker date); vuoto = nessun picker.
    private let dateOptions: [ExactTrenitaliaRef]
    private let loadRef: ((ExactTrenitaliaRef) async throws -> TrainJourney)?
    /// Numero treno (Trenitalia) da verificare in infomobilità; nil = nessun controllo
    /// (es. aperto DA infomobilità: l'utente è già al corrente).
    private let disserviceCheckNumber: String?
    @State private var selectedRef: ExactTrenitaliaRef?
    /// Corsa dei dati mostrati: se il cambio data fallisce il picker torna qui.
    @State private var loadedRef: ExactTrenitaliaRef?
    @State private var isChangingDate = false
    @State private var lastUpdated = Date()
    @State private var loadIssue: LoadIssue?
    @State private var showReport = false
    @State private var showSeatMap = false
    @State private var disserviceNumber: String?

    /// Aggiornamento automatico mentre la schermata è visibile.
    private static let autoRefreshInterval: Duration = .seconds(60)

    init(journey: TrainJourney,
         favorite: FavoriteTrain? = nil,
         dateOptions: [ExactTrenitaliaRef] = [],
         currentRef: ExactTrenitaliaRef? = nil,
         loadRef: ((ExactTrenitaliaRef) async throws -> TrainJourney)? = nil,
         disserviceCheckNumber: String? = nil,
         reload: (() async throws -> TrainJourney)? = nil) {
        _journey = State(initialValue: journey)
        self.favorite = favorite
        self.dateOptions = dateOptions
        self.loadRef = loadRef
        self.disserviceCheckNumber = disserviceCheckNumber
        _selectedRef = State(initialValue: currentRef ?? dateOptions.first)
        _loadedRef = State(initialValue: currentRef ?? dateOptions.first)
        self.reload = reload
    }

    var body: some View {
        ScrollView {
            // Larghezza regolare (schermo interno di iPhone Duo, iPad): intestazione
            // a sinistra e fermate a destra, separate dalla piega quando è attiva.
            DuoTwoColumns(spacing: 24) {
                header
                if dateOptions.count > 1 { datePicker }
            } trailing: {
                timeline
                    // Durante il cambio data le fermate mostrate sono della corsa precedente.
                    .opacity(isChangingDate ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.vertical, 20)
        }
        // Applicato allo ScrollView (innermost): così la .sheet esterna NON eredita
        // il pull-to-refresh (\.refresh non è azzerabile perché è get-only).
        .refreshable { await refresh() }
        .background(Color(.systemGroupedBackground))
        // Solo categoria + numero (es. "Frecciarossa 8519"); il vettore è nel badge.
        .navigationTitle(trainLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Titolo + simbolo su ogni pulsante: sulla barra si vede l'icona, nel menu
            // di troppo pieno (barre sul lato di iPhone Duo) e con VoiceOver il titolo.
            if canShowSeatMap {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSeatMap = true
                    } label: {
                        Label("Mappa dei posti", systemImage: "carseat.right.fill")
                    }
                }
                .visibilityPriorityIfAvailable(.high)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showReport = true
                } label: {
                    Label("Segnalazioni", systemImage: "exclamationmark.bubble")
                }
            }
            .visibilityPriorityIfAvailable(.low)
            if let favorite {
                ToolbarItem(placement: .topBarTrailing) {
                    // Riconosce anche i preferiti salvati senza origine.
                    let isSaved = favorites.contains(favorite)
                    Button {
                        favorites.toggle(favorite)
                    } label: {
                        Label(isSaved ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                              systemImage: isSaved ? "star.fill" : "star")
                            .foregroundStyle(isSaved ? .yellow : .accentColor)
                    }
                }
                .visibilityPriorityIfAvailable(.high)
            }
        }
        .sheet(isPresented: $showReport) {
            TrainReportView(number: journey.trainNumber,
                            route: "\(journey.origin) → \(journey.destination)")
        }
        .sheet(isPresented: $showSeatMap) {
            SeatMapView(carrier: seatMapCarrier ?? .trenitalia,
                        trainNumber: journey.trainNumber,
                        trainLabel: trainLabel,
                        stops: seatMapStops)
        }
        // task(id:) annulla il caricamento precedente se la data cambia ancora.
        .task(id: selectedRef) { await loadSelectedRef() }
        // Il disservizio riguarda una corsa precisa: si ricontrolla a ogni cambio data.
        .task(id: selectedRef) { await checkDisservice() }
        // Aggiornamento ogni minuto solo con l'app in primo piano; il task si annulla
        // da solo quando la schermata sparisce o la scena va in background.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if Date().timeIntervalSince(lastUpdated) >= 60 { await refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoRefreshInterval)
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    // Picker segmented con le date disponibili (es. "12 lug" / "13 lug").
    private var datePicker: some View {
        Picker("Data", selection: $selectedRef) {
            ForEach(dateOptions, id: \.self) { ref in
                Text(Self.dateLabel(ref.timestamp)).tag(Optional(ref))
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Caricamento

    /// Errore dell'ultimo caricamento: i dati già mostrati restano visibili.
    private struct LoadIssue: Equatable {
        let failure: TrainLoadFailure
        var failedRef: ExactTrenitaliaRef? = nil   // cambio data non riuscito
    }

    /// Ricarica la corsa mostrata (pull-to-refresh, automatico, Riprova).
    private func refresh() async {
        guard !isChangingDate else { return }
        let ref = selectedRef
        do {
            let updated: TrainJourney
            // Corsa esatta se nota: ricaricare per numero potrebbe aprire un altro treno.
            if let ref, let loadRef {
                updated = try await loadRef(ref)
            } else if let reload {
                updated = try await reload()
            } else {
                return
            }
            // Nel frattempo è stata scelta un'altra data: risposta superata.
            guard ref == selectedRef else { return }
            journey = updated
            loadedRef = ref
            lastUpdated = Date()
            loadIssue = nil
        } catch {
            guard ref == selectedRef, let failure = TrainLoadFailure(error) else { return }
            loadIssue = LoadIssue(failure: failure)
        }
    }

    /// Carica la corsa scelta nel picker date.
    private func loadSelectedRef() async {
        guard let ref = selectedRef, ref != loadedRef, let loadRef else { return }
        isChangingDate = true
        do {
            let updated = try await loadRef(ref)
            // Annullato: è stata scelta un'altra data, ci pensa il nuovo task.
            guard !Task.isCancelled else { return }
            journey = updated
            loadedRef = ref
            lastUpdated = Date()
            loadIssue = nil
        } catch {
            guard !Task.isCancelled else { return }
            if let failure = TrainLoadFailure(error) {
                loadIssue = LoadIssue(failure: failure, failedRef: ref)
            }
            // Il picker torna alla data dei dati mostrati invece di mentire.
            selectedRef = loadedRef
        }
        isChangingDate = false
    }

    private func retry(_ issue: LoadIssue) {
        loadIssue = nil
        if let ref = issue.failedRef {
            selectedRef = ref
        } else {
            Task { await refresh() }
        }
    }

    /// Verifica se il treno è colpito da un avviso in infomobilità per la corsa
    /// mostrata (origine e giorno); in tal caso mostra "Maggiori info sul disservizio".
    private func checkDisservice() async {
        disserviceNumber = nil
        guard let number = disserviceCheckNumber else { return }
        let origin = selectedRef?.codOrigine ?? journey.stops.first?.stationCode
        let day = selectedRef.map { Date(timeIntervalSince1970: TimeInterval($0.timestamp) / 1000) }
            ?? journey.departure
        let found = await InfomobilitaService.containsTrain(number, origin: origin, day: day)
        guard !Task.isCancelled, found else { return }
        disserviceNumber = number
    }

    private static let dateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        // Le date delle corse sono mezzanotte a Roma: in un altro fuso sarebbero il giorno prima.
        f.timeZone = TrainJourney.rome
        f.dateFormat = "d MMM"
        return f
    }()

    private static func dateLabel(_ millis: Int) -> String {
        dateLabelFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    // MARK: - Mappa posti

    /// Vettore della mappa posti: Trenitalia a prenotazione (Frecce, Intercity,
    /// EC/EN) o Italo. I regionali non hanno posti assegnati.
    private var seatMapCarrier: SeatMapCarrier? {
        if vettoreName.uppercased() == "ITALO" { return .italo }
        guard vettoreName == "Trenitalia" else { return nil }
        switch journey.categoryCode?.uppercased() {
        case "FR", "FA", "FB", "IC", "ICN", "EC", "EN": return .trenitalia
        default: return nil
        }
    }

    /// Fermate cercabili: senza soppresse e straordinarie; per Trenitalia solo
    /// quelle con codice stazione ViaggiaTreno (Italo risolve per nome).
    private var seatMapStops: [TrainStop] {
        journey.stops.filter { stop in
            !stop.isExtraordinary && !stop.isCancelled
                && (seatMapCarrier == .italo || stop.stationCode != nil)
        }
    }

    private var canShowSeatMap: Bool {
        seatMapCarrier != nil && !journey.isCancelled && seatMapStops.count >= 2
    }

    // MARK: - Header

    // Titolo diviso: prima parola = vettore (badge), resto = tipo treno + numero.
    private var vettoreName: String {
        journey.title.split(separator: " ", maxSplits: 1).first.map(String.init) ?? journey.title
    }
    private var trainLabel: String {
        let parts = journey.title.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : journey.trainNumber
    }

    private var header: some View {
        VStack(spacing: 16) {
            // Con le dimensioni di testo per l'accessibilità logo e titolo vanno in colonna.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    trainImage
                    titleBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    // Predisposizione immagine treno
                    trainImage
                    titleBlock
                    Spacer()
                }
            }

            if let notice = journey.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.alertText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            } else if let number = disserviceNumber {
                // Il treno è tra quelli con un avviso in infomobilità.
                Button { router.openInfomobilita(forTrain: number) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text("Maggiori info sul disservizio")
                            .font(.footnote.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.lateText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let issue = loadIssue {
                issueBanner(issue)
            }

            Divider()

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    positionSection
                    Divider()
                    delaySection
                }
            } else {
                HStack(spacing: 12) {
                    positionSection
                    Divider().frame(height: 40)
                    delaySection
                }
            }

            updatedFooter
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Vettore come badge sopra; tipo treno + numero come titolo.
            Text(vettoreName)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundColor(.secondary)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            Text(trainLabel)
                .font(.title3.weight(.bold))
            Text("\(journey.origin) → \(journey.destination)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// Aggiornamento fallito: i dati restano, con il motivo e un Riprova.
    private func issueBanner(_ issue: LoadIssue) -> some View {
        let text: String
        if let ref = issue.failedRef {
            text = "Impossibile caricare la corsa del \(Self.dateLabel(ref.timestamp)). \(issue.failure.message)"
        } else {
            text = "Aggiornamento non riuscito. \(issue.failure.message) Dati delle \(Self.hm(lastUpdated))."
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.failure.systemImage)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if issue.failure.canRetry {
                    Button("Riprova") { retry(issue) }
                        .font(.footnote.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "Aggiornato alle HH:mm" (o caricamento in corso del cambio data).
    private var updatedFooter: some View {
        HStack(spacing: 6) {
            if isChangingDate {
                ProgressView()
                    .controlSize(.small)
                Text("Caricamento della corsa…")
            } else {
                Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
                Text(updatedText)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var updatedText: String {
        var text = "Aggiornato alle \(Self.hm(lastUpdated))"
        // Italo dichiara l'ora dei propri dati: utile se è molto più vecchia.
        if let source = journey.dataUpdatedAt, abs(source.timeIntervalSince(lastUpdated)) >= 120 {
            text += " · dati del vettore delle \(Self.hm(source))"
        }
        return text
    }

    private var trainImage: some View {
        Group {
            if let category = journey.category, UIImage(named: category) != nil {
                Image(category)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "tram.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 60, height: 60)
        .background(Color.logoTile)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Decorativo: il titolo dice già il tipo treno (VoiceOver leggerebbe il nome dell'asset).
        .accessibilityHidden(true)
    }

    // Trenitalia fornisce l'ultimo rilevamento; gli altri la prossima fermata.
    private var positionSection: some View {
        let title: String
        let station: String
        let time: Date?

        if journey.isCancelled {
            title = "Posizione"
            station = "Treno soppresso"
            time = nil
        } else if journey.hasLivePosition {
            title = "Ultimo rilevamento"
            station = journey.lastDetectionStation ?? "--"
            time = journey.lastDetectionTime
        } else if let next = journey.nextStop {
            title = "Prossima fermata"
            station = next.stationName
            // Reale, poi stimato (programmato + ritardo), poi programmato; sull'origine
            // non c'è arrivo e conta la partenza.
            time = next.actualArrival ?? next.estimatedArrival ?? next.scheduledArrival
                ?? next.actualDeparture ?? next.estimatedDeparture ?? next.scheduledDeparture
        } else {
            title = "Prossima fermata"
            station = "Arrivato"
            time = nil
        }

        return VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(station)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.8)
            if let time {
                Text(Self.hm(time))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var delaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Stato", systemImage: statusSymbol)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(delayText)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(statusColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        if journey.isCancelled { return "xmark.circle" }
        return journey.delayMinutes > 0 ? "clock" : "checkmark.circle"
    }

    private var statusColor: Color {
        if journey.isCancelled { return .alertText }
        return journey.delayMinutes > 0 ? .alertText : .onTimeText
    }

    // Mostra il ritardo come da JSON: negativo = anticipo (verde),
    // positivo = ritardo (rosso), zero = in orario.
    private var delayText: String {
        // Un treno soppresso non è "In orario".
        if journey.isCancelled { return "Soppresso" }
        let d = journey.delayMinutes
        if d == 0 { return "In orario" }
        let n = abs(d)
        let unit = n == 1 ? "minuto" : "minuti"
        return d < 0 ? "Anticipo di \(n) \(unit)" : "In ritardo di \(n) \(unit)"
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Orari italiani: fuso di Roma anche con l'iPhone impostato altrove.
        f.timeZone = TrainJourney.rome
        f.dateFormat = "HH:mm"
        return f
    }()

    fileprivate static func hm(_ date: Date) -> String {
        hmFormatter.string(from: date)
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(Array(journey.stops.enumerated()), id: \.element.id) { index, stop in
                StopRow(stop: stop, isFirst: index == 0, isLast: index == journey.stops.count - 1)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Riga fermata (step)

private struct StopRow: View {
    let stop: TrainStop
    let isFirst: Bool
    let isLast: Bool

    private var circleColor: Color {
        if stop.isCancelled { return Color(.systemGray3) }
        if stop.isExtraordinary { return .yellow }
        return stop.isPassed ? .accentColor : Color(.systemGray4)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Indicatore + linea
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : (stop.isPassed ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .frame(width: 3, height: 14)

                Circle()
                    .fill(circleColor)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color(.secondarySystemGroupedBackground), lineWidth: 3)
                    )

                Rectangle()
                    .fill(isLast ? Color.clear : (stop.isPassed ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 16)

            // Contenuto
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.stationName)
                            .font(.body.weight(stop.isPassed || stop.isCancelled ? .regular : .semibold))
                            .foregroundColor(stop.isPassed || stop.isCancelled ? .secondary : .primary)
                            .strikethrough(stop.isCancelled)
                        if let orientation = stop.orientation {
                            Label(orientation, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if stop.isCancelled {
                            // Testo, non solo il barrato: il significato non resta affidato allo stile.
                            Text("Fermata soppressa")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundColor(.white)
                                .background(Color.alertText)
                                .clipShape(Capsule())
                        } else if stop.isExtraordinary {
                            Text("Fermata straordinaria")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundColor(.black)
                                .background(Color.yellow)
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                    if let platform = stop.platform, !stop.isCancelled {
                        PlatformBadge(platform: platform, confirmed: stop.platformConfirmed)
                    }
                }

                // Le colonne dipendono dai dati: il capolinea di partenza mostra
                // solo la partenza, quello d'arrivo solo l'arrivo.
                HStack(spacing: 20) {
                    if stop.scheduledArrival != nil || stop.actualArrival != nil {
                        TimeColumn(
                            title: "Arrivo",
                            scheduled: stop.scheduledArrival,
                            actual: stop.actualArrival,
                            estimated: stop.estimatedArrival,
                            cancelled: stop.isCancelled
                        )
                    }
                    if stop.scheduledDeparture != nil || stop.actualDeparture != nil {
                        TimeColumn(
                            title: "Partenza",
                            scheduled: stop.scheduledDeparture,
                            actual: stop.actualDeparture,
                            estimated: stop.estimatedDeparture,
                            cancelled: stop.isCancelled
                        )
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Una sola frase per fermata: VoiceOver leggeva i pezzi e perdeva barrato,
        // colori e binario confermato.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [stop.stationName]
        if stop.isCancelled {
            parts.append("fermata soppressa")
        } else {
            parts.append(stop.isPassed ? "fermata effettuata" : "fermata da effettuare")
            if stop.isExtraordinary { parts.append("fermata straordinaria") }
        }
        if stop.scheduledArrival != nil || stop.actualArrival != nil {
            parts.append(TimeColumn.spoken(title: "Arrivo", scheduled: stop.scheduledArrival,
                                           actual: stop.actualArrival, estimated: stop.estimatedArrival,
                                           cancelled: stop.isCancelled))
        }
        if stop.scheduledDeparture != nil || stop.actualDeparture != nil {
            parts.append(TimeColumn.spoken(title: "Partenza", scheduled: stop.scheduledDeparture,
                                           actual: stop.actualDeparture, estimated: stop.estimatedDeparture,
                                           cancelled: stop.isCancelled))
        }
        if let platform = stop.platform, !stop.isCancelled {
            parts.append("binario \(platform), \(stop.platformConfirmed ? "confermato" : "previsto")")
        }
        if let orientation = stop.orientation { parts.append(orientation) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Binario (chiaro = previsto, scuro = confermato)

private struct PlatformBadge: View {
    let platform: String
    let confirmed: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Spunta sul confermato: la differenza non è affidata solo al colore.
            if confirmed {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
            }
            Text("Bin.")
                .font(.caption2)
            Text(platform)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(confirmed ? Color(.systemBackground) : .primary)
        .background(confirmed ? Color.primary : Color(.systemGray5))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Binario \(platform), \(confirmed ? "confermato" : "previsto")")
    }
}

// MARK: - Colonna orario (previsto barrato + effettivo)

private struct TimeColumn: View {
    let title: String
    let scheduled: Date?
    let actual: Date?
    var estimated: Date? = nil
    var cancelled = false

    private static func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        return TrainView.hm(date)
    }

    // Orario "vivo": effettivo se disponibile, altrimenti previsto (stima).
    private var live: Date? { actual ?? estimated }

    /// Minuti di ritardo (da 1 in poi), nil se in orario o in anticipo.
    private static func delayMinutes(scheduled: Date?, live: Date?) -> Int? {
        guard let s = scheduled, let l = live else { return nil }
        let minutes = Int(TrainJourney.difference(l, from: s) / 60)
        return minutes >= 1 ? minutes : nil   // da 1 minuto in poi = in ritardo
    }

    private var delay: Int? { Self.delayMinutes(scheduled: scheduled, live: live) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                if cancelled {
                    // Fermata soppressa: solo l'orario programmato, barrato.
                    Text(Self.string(scheduled) ?? "--:--")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .strikethrough()
                } else if let live = Self.string(live) {
                    // Effettivo o previsto: verde se in orario/anticipo, arancione se in ritardo.
                    Text(live)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(delay != nil ? .lateText : .onTimeText)
                    // Programmato barrato solo se diverso.
                    if let sched = Self.string(scheduled), sched != live {
                        Text(sched)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .strikethrough()
                    }
                    // Minuti di ritardo scritti: il colore da solo non basta.
                    if let delay {
                        Text("+\(delay)′")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.lateText)
                    }
                } else if let sched = Self.string(scheduled) {
                    Text(sched)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("--:--")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Descrizione per VoiceOver, es. "Arrivo 10:07 effettivo, programmato 10:05, ritardo 2 minuti".
    static func spoken(title: String, scheduled: Date?, actual: Date?, estimated: Date?,
                       cancelled: Bool) -> String {
        let sched = string(scheduled)
        if cancelled { return "\(title) programmato \(sched ?? "non disponibile")" }
        guard let liveDate = actual ?? estimated, let live = string(liveDate) else {
            return "\(title) \(sched ?? "non disponibile")"
        }
        var text = "\(title) \(live) \(actual != nil ? "effettivo" : "previsto")"
        if let sched, sched != live { text += ", programmato \(sched)" }
        if let delay = delayMinutes(scheduled: scheduled, live: liveDate) {
            text += ", ritardo \(delay) \(delay == 1 ? "minuto" : "minuti")"
        } else if sched != nil {
            text += ", in orario"
        }
        return text
    }
}

// MARK: - Colori leggibili

private extension Color {
    // In modalità chiara le tinte di sistema su bianco stanno intorno a 2-3:1:
    // versioni più scure (almeno 4.5:1), quelle di sistema in modalità scura.
    static let onTimeText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.0, green: 0.48, blue: 0.2, alpha: 1)
    })
    static let lateText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.72, green: 0.33, blue: 0.0, alpha: 1)
    })
    static let alertText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.77, green: 0.1, blue: 0.1, alpha: 1)
    })
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TrainView(journey: .sample,
                  favorite: FavoriteTrain(vector: "Trenitalia", number: "9612",
                                          title: "Trenitalia Frecciarossa 9612",
                                          subtitle: "Napoli Centrale → Milano Centrale",
                                          category: "FRECCIAROSSA"))
    }
    .environmentObject(FavoritesStore())
    .environmentObject(AppRouter())
}

extension TrainJourney {
    static var sample: TrainJourney {
        let base = Date()
        func t(_ min: Int) -> Date { base.addingTimeInterval(TimeInterval(min * 60)) }

        return TrainJourney(
            trainNumber: "9612",
            title: "Trenitalia Frecciarossa 9612",
            category: "FRECCIAROSSA",
            origin: "Napoli Centrale",
            destination: "Milano Centrale",
            delayMinutes: -1,
            lastDetectionStation: "Bologna Centrale",
            lastDetectionTime: t(-3),
            stops: [
                TrainStop(stationName: "Napoli Centrale",
                          scheduledArrival: nil, actualArrival: nil,
                          scheduledDeparture: t(-180), actualDeparture: t(-180),
                          platform: "12", platformConfirmed: true, isPassed: true,
                          orientation: "Executive in coda",
                          isFirst: true, isLast: false),
                TrainStop(stationName: "Roma Termini",
                          scheduledArrival: t(-110), actualArrival: t(-108),
                          scheduledDeparture: t(-105), actualDeparture: t(-103),
                          platform: "5", platformConfirmed: true, isPassed: true,
                          orientation: "Executive in testa"),
                TrainStop(stationName: "Firenze S.M.N.",
                          scheduledArrival: t(-40), actualArrival: t(-35),
                          scheduledDeparture: t(-37), actualDeparture: t(-32),
                          platform: "9", platformConfirmed: true, isPassed: true,
                          orientation: "Executive in coda"),
                TrainStop(stationName: "Bologna Centrale",
                          scheduledArrival: t(-5), actualArrival: nil,
                          scheduledDeparture: t(-2), actualDeparture: nil,
                          platform: "3", platformConfirmed: false, isPassed: false,
                          orientation: "Executive in testa"),
                TrainStop(stationName: "Milano Centrale",
                          scheduledArrival: t(55), actualArrival: nil,
                          scheduledDeparture: nil, actualDeparture: nil,
                          platform: "18", platformConfirmed: false, isPassed: false,
                          orientation: "Executive in coda",
                          isFirst: false, isLast: true),
            ]
        )
    }
}
