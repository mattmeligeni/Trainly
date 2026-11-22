//
//  BigliettiView.swift
//  Trainly
//
//  Cerca biglietti: un unico form che interroga Trenitalia, Italo e Trenord ->
//  soluzioni con prezzi, divise per vettore + una vista "Principali" aggregata.
//

internal import SwiftUI
internal import Observation

struct BigliettiView: View {

    enum Field: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
    }
    enum CategoryFilter: String, CaseIterable, Identifiable {
        case tutti = "Tutti", frecce = "Frecce", intercity = "Intercity", regionali = "Regionali"
        var id: String { rawValue }
    }

    @State private var origin: TrenitaliaLocation?
    @State private var destination: TrenitaliaLocation?
    @State private var date = Date()
    @State private var adults = 1
    @State private var children = 0
    @State private var category: CategoryFilter = .tutti

    @State private var model = TicketSearchModel()
    @State private var picking: Field?
    @State private var showResults = false
    // Apre i risultati quando la ricerca avviata dal form finisce con almeno una soluzione.
    @State private var openWhenDone = false

    var body: some View {
        Form {
            Section("Tratta") {
                stationButton(.origin, "Partenza", origin)
                stationButton(.destination, "Arrivo", destination)
                HStack {
                    Button {
                        swap(&origin, &destination)
                    } label: {
                        Label("Inverti", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(origin == nil && destination == nil)
                    Spacer()
                    Button(role: .destructive, action: reset) {
                        Label("Resetta", systemImage: "xmark.circle")
                    }
                    .disabled(origin == nil && destination == nil && model.query == nil)
                }
                .buttonStyle(.borderless)
            }

            Section {
                // Orari italiani anche con l'iPhone in un altro fuso.
                DatePicker("Partenza", selection: $date, in: Date()...)
                    .environment(\.timeZone, TicketClock.timeZone)
            } header: {
                Text("Quando")
            } footer: {
                if TicketClock.deviceDiffers { Text("Orari in ora italiana.") }
            }

            Section("Passeggeri") {
                Stepper("Adulti: \(adults)", value: $adults, in: 1...9)
                Stepper("Bambini: \(children)", value: $children, in: 0...9)
            }

            Section {
                Picker("Categoria", selection: $category) {
                    ForEach(CategoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Filtri")
            } footer: {
                Text("La categoria si applica alle soluzioni Trenitalia.")
            }

            Section {
                Button(action: search) {
                    HStack {
                        if model.isLoading { ProgressView().padding(.trailing, 4) }
                        Text(model.isLoading ? "Ricerca…" : "Cerca biglietti")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(origin == nil || destination == nil || model.isLoading)
            }

            results

            Section {
                Text("Questa è solo una funzionalità di ricerca di orari e prezzi. Per l'acquisto rivolgiti ai canali ufficiali Trenitalia e Italo o ai rivenditori autorizzati. I treni regionali Trenord hanno una sezione dedicata.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Cerca Biglietti")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if model.query == nil { date = Date() } }   // ora corrente finché non si sceglie
        .task { await TrenitaliaStationsStore.shared.refreshIfNeeded() }
        .onChange(of: model.isLoading) { _, loading in
            guard !loading, openWhenDone else { return }
            openWhenDone = false
            if model.hasAnyResult { showResults = true }
        }
        .navigationDestination(isPresented: $showResults) {
            SolutionsListView(model: model)
        }
        .sheet(item: $picking) { field in
            StationSearchView(title: field == .origin ? "Stazione di partenza" : "Stazione di arrivo") { loc in
                if field == .origin { origin = loc } else { destination = loc }
                picking = nil
            }
        }
    }

    // MARK: - Input stazione

    private func stationButton(_ field: Field, _ title: String, _ station: TrenitaliaLocation?) -> some View {
        Button { picking = field } label: {
            HStack {
                Text(title).foregroundColor(.secondary)
                Spacer()
                Text(station?.label ?? "Scegli")
                    .foregroundColor(station == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("\(title): \(station?.label ?? "da scegliere")")
    }

    // MARK: - Risultati

    // Solo esito inline: la lista soluzioni si apre in una nuova pagina.
    @ViewBuilder
    private var results: some View {
        if model.query != nil, !model.isLoading {
            if model.hasAnyResult {
                Section {
                    Button(model.resultCount == 1 ? "Mostra 1 soluzione" : "Mostra \(model.resultCount) soluzioni") {
                        showResults = true
                    }
                        .frame(maxWidth: .infinity)
                }
            } else if model.failedCarriers.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nessuna soluzione", systemImage: "tram")
                    } description: {
                        Text(model.statusSummary)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Ricerca non riuscita", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(model.statusSummary)
                    } actions: {
                        Button("Riprova") {
                            openWhenDone = true
                            model.retryFailed()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func reset() {
        // Annulla anche la ricerca in corso: i suoi risultati non devono aprirsi.
        model.reset()
        openWhenDone = false
        showResults = false
        origin = nil
        destination = nil
    }

    private func search() {
        guard let o = origin, let d = destination else { return }
        openWhenDone = true
        // Parametri congelati: modifiche al form durante o dopo la ricerca non
        // cambiano i risultati né "Riprova".
        model.start(TicketQuery(origin: o, destination: d, date: date,
                                adults: adults, children: children, category: category))
    }

    static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Stato della ricerca (per vettore)

/// Parametri di una ricerca, fissati al tocco di "Cerca".
struct TicketQuery {
    let id = UUID()
    let origin: TrenitaliaLocation
    let destination: TrenitaliaLocation
    let date: Date
    let adults: Int
    let children: Int
    let category: BigliettiView.CategoryFilter

    // Se una delle stazioni è "( Tutte Le Stazioni )" mostriamo la stazione
    // specifica di partenza/arrivo in ogni soluzione.
    var isMultistation: Bool {
        isMultistationName(origin.label) || isMultistationName(destination.label)
    }
}

/// Esito per singolo vettore: vuoto, errore e "tratta non servita" sono distinti.
enum CarrierOutcome {
    case idle
    case loading
    case loaded([TicketSolution], partial: Bool)
    case notServed(String)
    case failed(String)

    var solutions: [TicketSolution] {
        if case .loaded(let sols, _) = self { return sols }
        return []
    }
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

@Observable
final class TicketSearchModel {
    private(set) var query: TicketQuery?
    private(set) var trenitalia: CarrierOutcome = .idle
    private(set) var italo: CarrierOutcome = .idle
    @ObservationIgnored private var tasks: [TicketCarrier: Task<Void, Never>] = [:]

    static let carriers: [TicketCarrier] = [.trenitalia, .italo]

    var isLoading: Bool { trenitalia.isLoading || italo.isLoading }
    var hasAnyResult: Bool { resultCount > 0 }
    var resultCount: Int { trenitalia.solutions.count + italo.solutions.count }
    var failedCarriers: [TicketCarrier] { Self.carriers.filter { outcome($0).isFailure } }

    func outcome(_ carrier: TicketCarrier) -> CarrierOutcome {
        carrier == .italo ? italo : trenitalia
    }

    /// Una riga per vettore, per lo stato vuoto/errore nel form.
    var statusSummary: String {
        Self.carriers.compactMap { carrier -> String? in
            let name = carrier.displayName
            switch outcome(carrier) {
            case .loaded(let sols, _) where sols.isEmpty: return "\(name): nessuna soluzione."
            case .notServed(let text): return text
            case .failed(let text): return "\(name): \(text)"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    func start(_ query: TicketQuery) {
        cancel()
        self.query = query
        for carrier in Self.carriers { load(carrier) }
    }

    func retry(_ carrier: TicketCarrier) { load(carrier) }

    func retryFailed() {
        for carrier in Self.carriers {
            switch outcome(carrier) {
            case .failed, .loaded(_, partial: true): load(carrier)
            default: break
            }
        }
    }

    func reset() {
        cancel()
        query = nil
        trenitalia = .idle
        italo = .idle
    }

    private func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    private func set(_ carrier: TicketCarrier, _ outcome: CarrierOutcome) {
        if carrier == .italo { italo = outcome } else { trenitalia = outcome }
    }

    private func load(_ carrier: TicketCarrier) {
        guard let query, carrier != .trenord else { return }
        tasks[carrier]?.cancel()
        set(carrier, .loading)
        tasks[carrier] = Task { [weak self] in
            let outcome = await Self.fetch(carrier, query)
            // Una ricerca più recente (o Resetta) ha la precedenza.
            guard let self, !Task.isCancelled, self.query?.id == query.id else { return }
            self.set(carrier, outcome)
        }
    }

    private static func fetch(_ carrier: TicketCarrier, _ q: TicketQuery) async -> CarrierOutcome {
        do {
            switch carrier {
            case .trenitalia:
                // Trenitalia (lefrecce): escludiamo le soluzioni di solo Trenord, che
                // hanno una sezione dedicata.
                let day = try await BigliettiService.searchDay(
                    fromId: q.origin.id, toId: q.destination.id, date: q.date,
                    adults: q.adults, children: q.children,
                    frecceOnly: q.category == .frecce,
                    regionalOnly: q.category == .regionali,
                    intercityOnly: q.category == .intercity)
                return .loaded(day.solutions.filter { !$0.isPureTrenord }, partial: !day.complete)
            case .italo:
                let sols = try await ItaloTicketService.search(
                    originName: q.origin.label, destName: q.destination.label, date: q.date,
                    adults: q.adults, children: q.children)
                return .loaded(sols, partial: false)
            case .trenord:
                return .idle
            }
        } catch {
            let e = TicketSearchError(error)
            if case .notServed(let text) = e { return .notServed(text) }
            return .failed(e.message)
        }
    }
}

extension TicketCarrier {
    var displayName: String {
        switch self {
        case .trenitalia: return "Trenitalia"
        case .italo: return "Italo"
        case .trenord: return "Trenord"
        }
    }
}

// MARK: - Lista soluzioni (pagina pushata)

struct SolutionsListView: View {

    enum Segment: String, CaseIterable, Identifiable {
        case principali = "Principali", trenitalia = "Trenitalia", italo = "Italo"
        var id: String { rawValue }
    }

    let model: TicketSearchModel

    @State private var segment: Segment = .principali
    @State private var changesFilter: ChangesFilter = .direct
    @State private var sort: TicketSort = .priceAsc

    private var showStations: Bool { model.query?.isMultistation ?? false }

    private var carriers: [TicketCarrier] {
        switch segment {
        case .principali: return TicketSearchModel.carriers
        case .trenitalia: return [.trenitalia]
        case .italo: return [.italo]
        }
    }

    private var baseList: [TicketSolution] {
        carriers.flatMap { model.outcome($0).solutions }
    }

    private var list: [TicketSolution] {
        baseList.filteredSorted(changes: changesFilter, sort: sort)
    }

    var body: some View {
        List {
            Section {
                Picker("Vettore", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                FilterSortControls(changes: $changesFilter, sort: $sort)
            }

            carrierNotices

            if list.isEmpty {
                emptyContent
            } else {
                Section {
                    ForEach(list) { sol in
                        NavigationLink {
                            SolutionDetailView(solution: sol)
                        } label: {
                            SolutionRow(solution: sol,
                                        showStations: showStations && sol.carrier == .trenitalia,
                                        showCarrier: segment == .principali)
                        }
                    }
                } footer: {
                    hiddenByChangesFooter
                }
            }
        }
        .navigationTitle("Soluzioni")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Stato dei vettori

    /// Avvisi per vettore (caricamento, errore con Riprova, tratta non servita,
    /// risultati parziali). Con un solo vettore e lista vuota ci pensa `emptyContent`.
    @ViewBuilder
    private var carrierNotices: some View {
        let single = carriers.count == 1 && list.isEmpty
        let rows = carriers.filter { carrier in
            switch model.outcome(carrier) {
            case .loading: return true
            case .failed, .notServed: return !single
            case .loaded(let sols, let partial): return partial || (sols.isEmpty && !single)
            case .idle: return false
            }
        }
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.self) { carrier in
                    carrierNotice(carrier)
                }
            }
        }
    }

    @ViewBuilder
    private func carrierNotice(_ carrier: TicketCarrier) -> some View {
        let name = carrier.displayName
        switch model.outcome(carrier) {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Ricerca \(name)…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            noticeWithRetry(carrier, "\(name): \(message)", icon: "exclamationmark.triangle.fill")
        case .loaded(_, partial: true):
            noticeWithRetry(carrier, "\(name): le soluzioni più tarde non sono state caricate.",
                            icon: "exclamationmark.triangle.fill")
        case .notServed(let message):
            Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
        case .loaded:
            Label("\(name): nessuna soluzione per questa tratta.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private func noticeWithRetry(_ carrier: TicketCarrier, _ text: String, icon: String) -> some View {
        HStack {
            Label(text, systemImage: icon)
                .symbolRenderingMode(.multicolor)
            Spacer()
            Button("Riprova") { model.retry(carrier) }
                .buttonStyle(.borderless)
        }
    }

    // MARK: Lista vuota

    @ViewBuilder
    private var emptyContent: some View {
        let only = carriers.count == 1 ? model.outcome(carriers[0]) : nil
        if let wider = changesFilter.widened(toShow: baseList) {
            // Il filtro cambi nasconde tutto: diciamo quante soluzioni ci sono e
            // offriamo di allargarlo.
            let hidden = changesFilter.hiddenCount(in: baseList)
            Section {
                ContentUnavailableView {
                    Label(changesFilter == .direct ? "Nessuna soluzione diretta" : "Nessuna soluzione con questi filtri",
                          systemImage: "arrow.triangle.branch")
                } description: {
                    Text(hidden == 1 ? "C'è 1 soluzione con cambi." : "Ci sono \(hidden) soluzioni con cambi.")
                } actions: {
                    Button("Mostra con cambi") { changesFilter = wider }
                        .buttonStyle(.bordered)
                }
            }
        } else if case .failed(let message) = only {
            Section {
                ContentUnavailableView {
                    Label("Ricerca \(carriers[0].displayName) non riuscita", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Riprova") { model.retry(carriers[0]) }
                        .buttonStyle(.bordered)
                }
            }
        } else if case .notServed(let message) = only {
            Section {
                ContentUnavailableView("Tratta non servita", systemImage: "mappin.slash",
                                       description: Text(message))
            }
        } else if !carriers.contains(where: { model.outcome($0).isLoading }) {
            Section {
                ContentUnavailableView("Nessuna soluzione", systemImage: "tram",
                                       description: Text(emptyMessage))
            }
        }
    }

    private var emptyMessage: String {
        segment == .principali
            ? "Nessuna soluzione con questi filtri."
            : "Nessuna soluzione \(segment.rawValue) con questi filtri."
    }

    @ViewBuilder
    private var hiddenByChangesFooter: some View {
        let hidden = changesFilter.hiddenCount(in: baseList)
        if hidden > 0, let wider = changesFilter.widened(toShow: baseList) {
            Button(hidden == 1 ? "Mostra 1 altra soluzione con cambi" : "Mostra altre \(hidden) soluzioni con cambi") {
                changesFilter = wider
            }
            .font(.footnote)
        }
    }
}

// MARK: - Barra filtri + ordinamento (condivisa)

struct FilterSortControls: View {
    @Binding var changes: ChangesFilter
    @Binding var sort: TicketSort

    var body: some View {
        Picker("Cambi", selection: $changes) {
            ForEach(ChangesFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("Ordina per", selection: $sort) {
            ForEach(TicketSort.allCases) { Text($0.rawValue).tag($0) }
        }
    }
}

// MARK: - Formattazione / componenti condivisi

func euroString(_ amount: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "EUR"
    f.locale = Locale(identifier: "it_IT")
    return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f €", amount)
}

/// Verde dei prezzi e di "Disponibile": più scuro in modalità chiara, dove il
/// `.green` di sistema su bianco ha un contrasto di circa 2:1.
func ticketGreen(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? .green : Color(red: 0.0, green: 0.48, blue: 0.2)
}

/// Logo treno su sfondo chiaro (come nel tabellone).
struct TicketTrainLogo: View {
    let imageName: String?
    var width: CGFloat = 40
    var height: CGFloat = 26

    var body: some View {
        Group {
            if let imageName, UIImage(named: imageName) != nil {
                Image(imageName).resizable().scaledToFit().padding(3)
            } else {
                Image(systemName: "tram.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: width, height: height)
        .background(Color.logoTile)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // VoiceOver leggerebbe il nome dell'asset ("TRENITALIA-3").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.brandName(imageName))
    }

    static func brandName(_ imageName: String?) -> String {
        switch imageName {
        case "FRECCIAROSSA": return "Frecciarossa"
        case "FRECCIARGENTO": return "Frecciargento"
        case "FRECCIABIANCA": return "Frecciabianca"
        case "INTERCITY-2": return "Intercity"
        case "LEONARDOEXP": return "Leonardo Express"
        case "TRENORD-2": return "Trenord"
        case "ITALO": return "Italo"
        case "TRENITALIA", "TRENITALIA-3": return "Trenitalia"
        default: return "Treno"
        }
    }
}

func ticketStatusText(_ status: String) -> String {
    switch status {
    case "SALEABLE": return "Disponibile"
    case "SOLD_OUT": return "Esaurito"
    default: return "Non disp."
    }
}

func ticketStatusBadge(_ status: String) -> some View {
    TicketStatusBadge(status: status)
}

struct TicketStatusBadge: View {
    let status: String
    @Environment(\.colorScheme) private var scheme

    private var color: Color {
        switch status {
        case "SALEABLE": return ticketGreen(scheme)
        case "SOLD_OUT": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(ticketStatusText(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundColor(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityLabel(status == "SALEABLE" || status == "SOLD_OUT" ? ticketStatusText(status) : "Non disponibile")
    }
}

/// "3 ore e 5 minuti" per VoiceOver ("3h 05m" verrebbe letto lettera per lettera).
func spokenDuration(_ minutes: Int?, fallback: String) -> String {
    guard let minutes else { return fallback }
    let (h, m) = (minutes / 60, minutes % 60)
    let hours = h == 1 ? "1 ora" : "\(h) ore"
    let mins = m == 1 ? "1 minuto" : "\(m) minuti"
    if h == 0 { return mins }
    return m == 0 ? hours : "\(hours) e \(mins)"
}

// MARK: - Riga soluzione

struct SolutionRow: View {
    let solution: TicketSolution
    var showStations = false
    var showCarrier = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TicketTrainLogo(imageName: solution.trains.first?.logoImageName)
                Text(trainsSummary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                ticketStatusBadge(solution.status)
            }

            if showCarrier {
                Text(solution.carrier.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            if showStations {
                Text("\(solution.origin) → \(solution.destination)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Label("\(solution.departure) → \(solution.arrival)", systemImage: "clock")
                Text(solution.duration)
                Spacer()
                Text(solution.changesText)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let price = solution.minPrice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("da " + euroString(price))
                        .font(.headline)
                        .foregroundStyle(ticketGreen(scheme))
                    if let scope = solution.priceScopeText {
                        Text(scope).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // Una sola frase per VoiceOver invece di tanti pezzi.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var trainsSummary: String {
        let parts = solution.trains.map(\.label).filter { !$0.isEmpty }
        return parts.isEmpty ? "\(solution.origin) → \(solution.destination)" : parts.joined(separator: " › ")
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if showCarrier { parts.append(solution.carrier.displayName) }
        parts.append(solution.trains.map(\.label).filter { !$0.isEmpty }.joined(separator: ", poi "))
        if showStations { parts.append("da \(solution.origin) a \(solution.destination)") }
        parts.append("partenza \(solution.departure), arrivo \(solution.arrival)")
        parts.append("durata \(spokenDuration(solution.durationMinutes, fallback: solution.duration))")
        parts.append(solution.changesText)
        if let price = solution.minPrice {
            var text = "da \(euroString(price))"
            if let scope = solution.priceScopeText { text += " \(scope)" }
            parts.append(text)
        }
        parts.append(solution.status == "SALEABLE" || solution.status == "SOLD_OUT"
                     ? ticketStatusText(solution.status) : "non disponibile")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Dettaglio soluzione

struct SolutionDetailView: View {
    let solution: TicketSolution

    @Environment(\.colorScheme) private var scheme

    private var allOffers: [TicketOffer] { solution.services.flatMap(\.offers) }

    var body: some View {
        List {
            Section {
                HStack {
                    ticketStatusBadge(solution.status)
                    Spacer()
                    Text(solution.changesText)
                        .font(.caption).foregroundColor(.secondary)
                    Text(solution.duration).font(.caption).foregroundColor(.secondary)
                        .accessibilityLabel(spokenDuration(solution.durationMinutes, fallback: solution.duration))
                }
                .accessibilityElement(children: .combine)
                ForEach(solution.trains) { train in
                    HStack(spacing: 10) {
                        TicketTrainLogo(imageName: train.logoImageName)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(train.label).font(.subheadline.weight(.semibold))
                            Text("\(train.departureStation) \(train.departure) → \(train.arrivalStation) \(train.arrival)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .accessibilityLabel("da \(train.departureStation) alle \(train.departure) a \(train.arrivalStation) alle \(train.arrival)")
                            trainExtras(train)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("\(solution.origin) → \(solution.destination)")
            }

            Section {
                // Classi collassabili, tutte chiuse di default.
                ForEach(solution.services) { service in
                    DisclosureGroup {
                        ForEach(service.offers) { offer in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(offer.name).font(.subheadline)
                                    Spacer()
                                    if let amount = offer.amount {
                                        Text(euroString(amount)).font(.subheadline.weight(.semibold))
                                    }
                                }
                                // Icone modificabilità/rimborso solo se l'info è disponibile.
                                HStack(spacing: 8) {
                                    if (1...20).contains(offer.seats) {
                                        Text("\(offer.seats) posti").foregroundColor(.orange)
                                    }
                                    if let changeable = offer.changeable {
                                        Image(systemName: changeable ? "arrow.triangle.2.circlepath" : "lock")
                                            .accessibilityLabel(changeable ? "Modificabile" : "Non modificabile")
                                    }
                                    if offer.refundable == true {
                                        Image(systemName: "eurosign.arrow.circlepath")
                                            .accessibilityLabel("Rimborsabile")
                                    }
                                    if let detail = offer.detail {
                                        Text(detail).lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 1)
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        HStack {
                            Text(service.group).font(.subheadline.weight(.semibold))
                            Spacer()
                            if let min = service.offers.compactMap(\.amount).min() {
                                Text("da " + euroString(min)).foregroundColor(ticketGreen(scheme))
                            }
                        }
                    }
                }
            } header: {
                Text("Prezzi e classi")
            } footer: {
                if let scope = solution.priceScopeText { Text("Prezzi \(scope).") }
            }

            if !solution.messages.isEmpty {
                Section("Avvisi") {
                    ForEach(solution.messages, id: \.self) { msg in
                        Label(msg, systemImage: "info.circle").font(.caption)
                    }
                }
            }

            if let co2 = solution.co2 {
                Section {
                    Label(co2, systemImage: "leaf").font(.caption).foregroundColor(ticketGreen(scheme))
                }
            }

            // Legenda solo per le icone effettivamente mostrate (Trenord non ne ha).
            if hasLegend {
                Section("Legenda") {
                    if allOffers.contains(where: { (1...20).contains($0.seats) }) {
                        legendRow("person.2", "«N posti»: pochi posti rimasti", .orange)
                    }
                    if allOffers.contains(where: { $0.changeable == true }) {
                        legendRow("arrow.triangle.2.circlepath", "Tariffa modificabile", .secondary)
                    }
                    if allOffers.contains(where: { $0.changeable == false }) {
                        legendRow("lock", "Tariffa non modificabile", .secondary)
                    }
                    if allOffers.contains(where: { $0.refundable == true }) {
                        legendRow("eurosign.arrow.circlepath", "Tariffa rimborsabile", .secondary)
                    }
                }
            }
        }
        .navigationTitle("Dettaglio soluzione")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasLegend: Bool {
        allOffers.contains { (1...20).contains($0.seats) || $0.changeable != nil || $0.refundable == true }
    }

    /// Info aggiuntive del treno, mostrate solo se disponibili (es. Trenord:
    /// affluenza, bici, accessibilità, ritardo).
    @ViewBuilder
    private func trainExtras(_ train: TicketTrain) -> some View {
        let hasAny = train.crowdingPercent != nil || train.bikeAllowed == true
            || train.accessible == true || train.delayMinutes != nil || train.secondClassOnly == true
        if hasAny {
            HStack(spacing: 10) {
                if let c = train.crowdingPercent {
                    Label("\(c)%", systemImage: "person.3.fill")
                        .foregroundColor(crowdColor(train.crowdingLabel))
                        .accessibilityLabel(crowdText(c, train.crowdingLabel))
                }
                if train.bikeAllowed == true {
                    Image(systemName: "bicycle").accessibilityLabel("Bici ammesse")
                }
                if train.accessible == true {
                    Image(systemName: "figure.roll").accessibilityLabel("Accessibile")
                }
                if train.secondClassOnly == true {
                    Text("2ª cl.").accessibilityLabel("Solo seconda classe")
                }
                if let d = train.delayMinutes {
                    Label("+\(d)'", systemImage: "clock.badge.exclamationmark").foregroundColor(.orange)
                        .accessibilityLabel("Ritardo \(d) minuti")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    private func crowdColor(_ label: String?) -> Color {
        switch label {
        case "uncrowded": return ticketGreen(scheme)
        case "average": return scheme == .dark ? .yellow : .brown
        case "crowded": return .orange
        default: return .secondary
        }
    }

    /// Affollamento a parole: il colore da solo non basta.
    private func crowdText(_ percent: Int, _ label: String?) -> String {
        let level: String
        switch label {
        case "uncrowded": level = ", poco affollato"
        case "average": level = ", affollamento medio"
        case "crowded": level = ", affollato"
        default: level = ""
        }
        return "Affollamento \(percent) per cento\(level)"
    }

    private func legendRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color).frame(width: 22)
                .accessibilityHidden(true)
            Text(text).font(.caption)
            Spacer()
        }
    }
}

// MARK: - Ricerca stazione (sheet)

struct StationSearchView: View {
    let title: String
    let onSelect: (TrenitaliaLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    // Osservato: al primo avvio il catalogo arriva mentre il foglio è aperto.
    @ObservedObject private var store = TrenitaliaStationsStore.shared
    @State private var query = ""
    @State private var apiResults: [TrenitaliaLocation] = []
    @State private var apiError: String?
    @State private var resolving = false
    @State private var resolveError: String?
    @State private var resolveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    // Se il catalogo è in cache usiamo i suggerimenti locali (istantanei).
    private var useLocal: Bool { !store.stations.isEmpty }
    private var localSuggestions: [CruscottoEntry] { store.suggest(query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    TextField("Cerca stazione…", text: $query)
                        .autocorrectionDisabled()
                        .focused($focused)
                    if !query.isEmpty {
                        Button { query = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Cancella testo")
                    }
                }
                .padding(14)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    if let message = resolveError ?? (useLocal ? nil : apiError) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if useLocal {
                        ForEach(localSuggestions) { entry in
                            Button { resolve(entry) } label: { stationRow(entry.text) }
                        }
                    } else {
                        ForEach(apiResults) { loc in
                            Button { onSelect(loc) } label: { stationRow(loc.label) }
                        }
                    }
                }
                .listStyle(.plain)
                // Un tocco alla volta: niente risoluzioni concorrenti.
                .disabled(resolving)
                .overlay {
                    if resolving { ProgressView() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
            .task { await store.refreshIfNeeded() }   // controllo settimanale
            .task(id: query) {
                resolveError = nil
                // Path API solo se il catalogo non è ancora in cache.
                guard !useLocal else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let results = try await BigliettiService.searchLocations(query)
                    guard !Task.isCancelled else { return }
                    apiResults = results
                    apiError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    apiError = "Ricerca stazioni non riuscita. " + TicketSearchError(error).message
                }
            }
            .onAppear { focused = true }
            .onDisappear { resolveTask?.cancel() }
        }
        .modalKeyboardSafe()
    }

    private func stationRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns").foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(name).foregroundColor(.primary)
        }
    }

    /// Risolve l'id numerico della stazione (serve per la ricerca soluzioni).
    /// Solo una corrispondenza certa: altrimenti lo diciamo invece di scegliere
    /// una stazione a caso.
    private func resolve(_ entry: CruscottoEntry) {
        resolveTask?.cancel()
        resolveError = nil
        resolving = true
        resolveTask = Task {
            do {
                let locations = try await BigliettiService.searchLocations(entry.text)
                guard !Task.isCancelled else { return }
                resolving = false
                if let best = BigliettiService.bestMatch(locations, for: [entry.text, entry.value]) {
                    onSelect(best)
                } else {
                    resolveError = "«\(entry.text)» non è tra le stazioni in vendita su Trenitalia."
                }
            } catch {
                guard !Task.isCancelled else { return }
                resolving = false
                resolveError = "Impossibile verificare la stazione. " + TicketSearchError(error).message
            }
        }
    }
}

#Preview {
    NavigationStack { BigliettiView() }
}
