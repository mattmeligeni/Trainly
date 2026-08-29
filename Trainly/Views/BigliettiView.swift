//
//  BigliettiView.swift
//  Trainly
//
//  Cerca biglietti: un unico form che interroga Trenitalia, Italo e Trenord ->
//  soluzioni con prezzi, divise per vettore + una vista "Principali" aggregata.
//

internal import SwiftUI

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

    @State private var trenitaliaSolutions: [TicketSolution] = []
    @State private var italoSolutions: [TicketSolution] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searched = false
    @State private var picking: Field?
    @State private var showResults = false

    // Se una delle stazioni è "( Tutte Le Stazioni )" mostriamo la stazione
    // specifica di partenza/arrivo in ogni soluzione.
    private var isMultistation: Bool {
        (origin?.label.localizedCaseInsensitiveContains("Tutte") ?? false)
        || (destination?.label.localizedCaseInsensitiveContains("Tutte") ?? false)
    }

    private var hasAnyResult: Bool {
        !trenitaliaSolutions.isEmpty || !italoSolutions.isEmpty
    }

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
                    .disabled(origin == nil && destination == nil && !hasAnyResult)
                }
                .buttonStyle(.borderless)
            }

            Section("Quando") {
                DatePicker("Partenza", selection: $date, in: Date()...)
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
                        if isLoading { ProgressView().padding(.trailing, 4) }
                        Text(isLoading ? "Ricerca…" : "Cerca biglietti")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(origin == nil || destination == nil || isLoading)
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
        .onAppear { if !searched { date = Date() } }   // ora corrente finché non si sceglie
        .task { await TrenitaliaStationsStore.shared.refreshIfNeeded() }
        .navigationDestination(isPresented: $showResults) {
            SolutionsListView(trenitalia: trenitaliaSolutions,
                              italo: italoSolutions,
                              showStations: isMultistation)
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
    }

    // MARK: - Risultati

    // Solo errore/vuoto inline: la lista soluzioni si apre in una nuova pagina.
    @ViewBuilder
    private var results: some View {
        if let errorMessage, !isLoading {
            Section { Text(errorMessage).foregroundColor(.secondary) }
        } else if searched && !hasAnyResult && !isLoading {
            Section { Text("Nessuna soluzione trovata").foregroundColor(.secondary) }
        }
    }

    private func reset() {
        origin = nil
        destination = nil
        trenitaliaSolutions = []
        italoSolutions = []
        searched = false
        errorMessage = nil
    }

    private func search() {
        guard let o = origin, let d = destination else { return }
        isLoading = true
        errorMessage = nil
        searched = true

        let originName = o.label
        let destName = d.label
        let cat = category

        Task {
            // Trenitalia (lefrecce): escludiamo le soluzioni di solo Trenord, che
            // hanno una sezione dedicata.
            async let trenitalia = Self.searchTrenitalia(
                fromId: o.id, toId: d.id, date: date,
                adults: adults, children: children, category: cat)

            async let italo = ItaloTicketService.search(
                originName: originName, destName: destName, date: date,
                adults: adults, children: children)

            let (tSols, iSols) = await (trenitalia, italo)
            trenitaliaSolutions = tSols
            italoSolutions = iSols

            if hasAnyResult {
                showResults = true
            } else {
                errorMessage = "Nessuna soluzione trovata per questa tratta."
            }
            isLoading = false
        }
    }

    private static func searchTrenitalia(fromId: Int, toId: Int, date: Date,
                                         adults: Int, children: Int,
                                         category: CategoryFilter) async -> [TicketSolution] {
        do {
            let sols = try await BigliettiService.searchSolutions(
                fromId: fromId, toId: toId, date: date,
                adults: adults, children: children,
                frecceOnly: category == .frecce,
                regionalOnly: category == .regionali,
                intercityOnly: category == .intercity)
            return sols.filter { !$0.isPureTrenord }
        } catch {
            return []
        }
    }

    static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Lista soluzioni (pagina pushata)

struct SolutionsListView: View {

    enum Segment: String, CaseIterable, Identifiable {
        case principali = "Principali", trenitalia = "Trenitalia", italo = "Italo"
        var id: String { rawValue }
    }

    let trenitalia: [TicketSolution]
    let italo: [TicketSolution]
    let showStations: Bool

    @State private var segment: Segment = .principali
    @State private var changesFilter: ChangesFilter = .direct
    @State private var sort: TicketSort = .priceAsc

    private var baseList: [TicketSolution] {
        switch segment {
        case .principali: return trenitalia + italo
        case .trenitalia: return trenitalia
        case .italo: return italo
        }
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

            if list.isEmpty {
                Section { Text(emptyMessage).foregroundColor(.secondary) }
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
                }
            }
        }
        .navigationTitle("Soluzioni")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyMessage: String {
        segment == .principali
            ? "Nessuna soluzione con questi filtri."
            : "Nessuna soluzione \(segment.rawValue) con questi filtri."
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
    }
}

func ticketStatusBadge(_ status: String) -> some View {
    let (text, color): (String, Color)
    switch status {
    case "SALEABLE": (text, color) = ("Disponibile", .green)
    case "SOLD_OUT": (text, color) = ("Esaurito", .red)
    default: (text, color) = ("Non disp.", .secondary)
    }
    return Text(text)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundColor(color)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
}

// MARK: - Riga soluzione

struct SolutionRow: View {
    let solution: TicketSolution
    var showStations = false
    var showCarrier = false

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
                Text(carrierName)
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
                Text(solution.direct ? "Diretto" : "\(solution.changes) cambi")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let price = solution.minPrice {
                Text("da " + euroString(price))
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var trainsSummary: String {
        let parts = solution.trains.map(\.label).filter { !$0.isEmpty }
        return parts.isEmpty ? "\(solution.origin) → \(solution.destination)" : parts.joined(separator: " › ")
    }

    private var carrierName: String {
        switch solution.carrier {
        case .trenitalia: return "Trenitalia"
        case .italo: return "Italo"
        case .trenord: return "Trenord"
        }
    }
}

// MARK: - Dettaglio soluzione

struct SolutionDetailView: View {
    let solution: TicketSolution

    var body: some View {
        List {
            Section {
                HStack {
                    ticketStatusBadge(solution.status)
                    Spacer()
                    Text(solution.direct ? "Diretto" : "\(solution.changes) cambi")
                        .font(.caption).foregroundColor(.secondary)
                    Text(solution.duration).font(.caption).foregroundColor(.secondary)
                }
                ForEach(solution.trains) { train in
                    HStack(spacing: 10) {
                        TicketTrainLogo(imageName: train.logoImageName)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(train.label).font(.subheadline.weight(.semibold))
                            Text("\(train.departureStation) \(train.departure) → \(train.arrivalStation) \(train.arrival)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            trainExtras(train)
                        }
                    }
                }
            } header: {
                Text("\(solution.origin) → \(solution.destination)")
            }

            Section("Prezzi e classi") {
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
                                    }
                                    if offer.refundable == true {
                                        Image(systemName: "eurosign.arrow.circlepath")
                                    }
                                    if let detail = offer.detail {
                                        Text(detail).lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                    } label: {
                        HStack {
                            Text(service.group).font(.subheadline.weight(.semibold))
                            Spacer()
                            if let min = service.offers.compactMap(\.amount).min() {
                                Text("da " + euroString(min)).foregroundColor(.green)
                            }
                        }
                    }
                }
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
                    Label(co2, systemImage: "leaf").font(.caption).foregroundColor(.green)
                }
            }

            Section("Legenda") {
                legendRow("person.2", "«N posti»: pochi posti rimasti", .orange)
                legendRow("arrow.triangle.2.circlepath", "Tariffa modificabile", .secondary)
                legendRow("lock", "Tariffa non modificabile", .secondary)
                legendRow("eurosign.arrow.circlepath", "Tariffa rimborsabile", .secondary)
            }
        }
        .navigationTitle("Dettaglio soluzione")
        .navigationBarTitleDisplayMode(.inline)
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
                }
                if train.bikeAllowed == true { Image(systemName: "bicycle") }
                if train.accessible == true { Image(systemName: "figure.roll") }
                if train.secondClassOnly == true { Text("2ª cl.") }
                if let d = train.delayMinutes {
                    Label("+\(d)'", systemImage: "clock.badge.exclamationmark").foregroundColor(.orange)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    private func crowdColor(_ label: String?) -> Color {
        switch label {
        case "uncrowded": return .green
        case "average": return .yellow
        case "crowded": return .orange
        default: return .secondary
        }
    }

    private func legendRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color).frame(width: 22)
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
    @State private var query = ""
    @State private var apiResults: [TrenitaliaLocation] = []
    @State private var resolving = false
    @FocusState private var focused: Bool

    // Se il catalogo è in cache usiamo i suggerimenti locali (istantanei).
    private var useLocal: Bool { !TrenitaliaStationsStore.shared.stations.isEmpty }
    private var localSuggestions: [CruscottoEntry] { TrenitaliaStationsStore.shared.suggest(query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Cerca stazione…", text: $query)
                        .autocorrectionDisabled()
                        .focused($focused)
                    if !query.isEmpty {
                        Button { query = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    if useLocal {
                        ForEach(localSuggestions) { entry in
                            Button { resolve(entry.text) } label: { stationRow(entry.text) }
                        }
                    } else {
                        ForEach(apiResults) { loc in
                            Button { onSelect(loc) } label: { stationRow(loc.label) }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if resolving { ProgressView() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
            .task { await TrenitaliaStationsStore.shared.refreshIfNeeded() }   // controllo settimanale
            .task(id: query) {
                // Path API solo se il catalogo non è ancora in cache.
                guard !useLocal else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                apiResults = await BigliettiService.searchStations(query)
            }
            .onAppear { focused = true }
        }
        .modalKeyboardSafe()
    }

    private func stationRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns").foregroundStyle(.tint)
            Text(name).foregroundColor(.primary)
        }
    }

    /// Risolve l'id numerico della stazione (serve per la ricerca soluzioni).
    private func resolve(_ name: String) {
        resolving = true
        Task {
            let locations = await BigliettiService.searchStations(name)
            resolving = false
            let best = locations.first { $0.label.caseInsensitiveCompare(name) == .orderedSame } ?? locations.first
            if let best { onSelect(best) }
        }
    }
}

#Preview {
    NavigationStack { BigliettiView() }
}
