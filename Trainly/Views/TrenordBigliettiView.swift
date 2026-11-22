//
//  TrenordBigliettiView.swift
//  Trainly
//
//  Ricerca biglietti Trenord (sezione dedicata del tab Utilità). Usa il catalogo
//  stazioni Trenord (nomi precisi) e la ricerca hafas paginata a 5 per pagina.
//

internal import SwiftUI

struct TrenordBigliettiView: View {

    enum Field: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
    }

    /// Esito della prima pagina: errore e "non servita" distinti da "nessuna soluzione".
    enum SearchState {
        case idle, loading
        case loaded(TrenordSearchResult)
        case notServed(String)
        case failed(String)
    }

    @State private var origin: String?          // nome esatto della stazione Trenord
    @State private var destination: String?
    @State private var date = Date()

    @State private var state: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var picking: Field?
    @State private var showResults = false

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }
    private var result: TrenordSearchResult? {
        if case .loaded(let r) = state { return r }
        return nil
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
                    .disabled(origin == nil && destination == nil && result == nil)
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

            outcome

            Section {
                Text("Ricerca di orari e prezzi dei treni regionali Trenord. Per l'acquisto usa i canali ufficiali Trenord.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Biglietti Trenord")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if case .idle = state { date = Date() } }
        .task { await TrenordStationsStore.shared.refreshIfNeeded() }
        .navigationDestination(isPresented: $showResults) {
            if let result {
                TrenordSolutionsView(result: result)
            }
        }
        .sheet(item: $picking) { field in
            TrenordStationSearchView(title: field == .origin ? "Stazione di partenza" : "Stazione di arrivo") { name in
                if field == .origin { origin = name } else { destination = name }
                picking = nil
            }
        }
    }

    private func stationButton(_ field: Field, _ title: String, _ station: String?) -> some View {
        Button { picking = field } label: {
            HStack {
                Text(title).foregroundColor(.secondary)
                Spacer()
                Text(station ?? "Scegli")
                    .foregroundColor(station == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("\(title): \(station ?? "da scegliere")")
    }

    @ViewBuilder
    private var outcome: some View {
        switch state {
        case .loaded(let r) where r.solutions.isEmpty:
            Section {
                ContentUnavailableView("Nessuna soluzione", systemImage: "tram",
                                       description: Text("Nessuna soluzione Trenord per questa tratta."))
            }
        case .loaded(let r):
            Section {
                Button(r.solutions.count == 1 ? "Mostra 1 soluzione" : "Mostra \(r.solutions.count) soluzioni") {
                    showResults = true
                }
                .frame(maxWidth: .infinity)
            }
        case .notServed(let message):
            Section {
                ContentUnavailableView("Tratta non servita", systemImage: "mappin.slash",
                                       description: Text(message))
            }
        case .failed(let message):
            Section {
                ContentUnavailableView {
                    Label("Ricerca non riuscita", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Riprova", action: search)
                        .buttonStyle(.bordered)
                        .disabled(origin == nil || destination == nil)
                }
            }
        case .idle, .loading:
            EmptyView()
        }
    }

    private func reset() {
        // Annulla anche la ricerca in corso: i suoi risultati non devono aprirsi.
        searchTask?.cancel()
        searchTask = nil
        state = .idle
        showResults = false
        origin = nil
        destination = nil
    }

    private func search() {
        guard let o = origin, let d = destination else { return }
        searchTask?.cancel()
        state = .loading
        // Parametri congelati al tocco di "Cerca".
        let from = BigliettiView.hhmm(date)
        let searchDate = date
        searchTask = Task {
            do {
                let r = try await TrenordTicketService.firstPage(
                    originName: o, destName: d, date: searchDate, fromTime: from)
                guard !Task.isCancelled else { return }
                state = .loaded(r)
                if !r.solutions.isEmpty { showResults = true }
            } catch {
                guard !Task.isCancelled else { return }
                let e = TicketSearchError(error)
                if case .notServed(let text) = e { state = .notServed(text) } else { state = .failed(e.message) }
            }
        }
    }
}

// MARK: - Lista soluzioni Trenord (con paginazione)

struct TrenordSolutionsView: View {
    let result: TrenordSearchResult

    @State private var solutions: [TicketSolution]
    @State private var lastTime: String?
    @State private var changesFilter: ChangesFilter = .direct
    @State private var sort: TicketSort = .priceAsc
    @State private var loadingMore = false
    @State private var noMore: Bool
    @State private var loadMoreError: String?

    init(result: TrenordSearchResult) {
        self.result = result
        _solutions = State(initialValue: result.solutions)
        _lastTime = State(initialValue: result.lastDepTime)
        _noMore = State(initialValue: result.endOfDay)
    }

    private var list: [TicketSolution] {
        solutions.filteredSorted(changes: changesFilter, sort: sort)
    }

    var body: some View {
        List {
            Section {
                FilterSortControls(changes: $changesFilter, sort: $sort)
            }

            if list.isEmpty {
                emptyContent
            } else {
                Section {
                    ForEach(list) { sol in
                        NavigationLink {
                            SolutionDetailView(solution: sol)
                        } label: {
                            SolutionRow(solution: sol)
                        }
                    }
                } footer: {
                    hiddenByChangesFooter
                }
            }

            if let loadMoreError {
                // Errore di rete: non è la fine della lista, si può riprovare.
                Section {
                    HStack {
                        Label(loadMoreError, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                        Spacer()
                        Button("Riprova", action: loadMore)
                            .buttonStyle(.borderless)
                            .disabled(loadingMore)
                    }
                }
            } else if !noMore, !solutions.isEmpty {
                Section {
                    Button(action: loadMore) {
                        HStack {
                            if loadingMore { ProgressView().padding(.trailing, 4) }
                            Text(loadingMore ? "Caricamento…" : "Mostra successivi")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(loadingMore)
                } footer: {
                    if sort != .departure {
                        Text("Le soluzioni successive vengono inserite secondo l'ordinamento scelto.")
                    }
                }
            }
        }
        .navigationTitle("Soluzioni Trenord")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var emptyContent: some View {
        if let wider = changesFilter.widened(toShow: solutions) {
            // Il filtro cambi nasconde tutto: diciamo quante soluzioni ci sono e
            // offriamo di allargarlo.
            let hidden = changesFilter.hiddenCount(in: solutions)
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
        } else {
            Section {
                ContentUnavailableView("Nessuna soluzione", systemImage: "tram",
                                       description: Text("Nessuna soluzione con questi filtri."))
            }
        }
    }

    @ViewBuilder
    private var hiddenByChangesFooter: some View {
        let hidden = changesFilter.hiddenCount(in: solutions)
        if hidden > 0, let wider = changesFilter.widened(toShow: solutions) {
            Button(hidden == 1 ? "Mostra 1 altra soluzione con cambi" : "Mostra altre \(hidden) soluzioni con cambi") {
                changesFilter = wider
            }
            .font(.footnote)
        }
    }

    private func loadMore() {
        guard let last = lastTime, !loadingMore else { return }
        // Dopo le 23:59 la giornata è finita.
        guard let from = TrenordTime.nextMinute(last) else { noMore = true; return }
        loadingMore = true
        loadMoreError = nil
        Task {
            defer { loadingMore = false }
            do {
                let page = try await TrenordTicketService.page(
                    trenordOrigin: result.trenordOrigin, trenordDestination: result.trenordDestination,
                    date: result.date, fromTime: from)
                let existing = Set(solutions.map(\.id))
                let fresh = page.solutions.filter { !existing.contains($0.id) }
                solutions.append(contentsOf: fresh)
                if let newLast = page.lastDepTime { lastTime = newLast }
                if fresh.isEmpty || page.endOfDay || page.lastDepTime == nil { noMore = true }
            } catch {
                loadMoreError = "Caricamento non riuscito. " + TicketSearchError(error).message
            }
        }
    }
}

// MARK: - Ricerca stazione Trenord (sheet)

struct TrenordStationSearchView: View {
    let title: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    // Osservato: al primo avvio il catalogo arriva mentre il foglio è aperto.
    @ObservedObject private var store = TrenordStationsStore.shared
    @State private var query = ""
    @State private var catalogFailed = false
    @FocusState private var focused: Bool

    private var suggestions: [String] { store.suggest(query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    TextField("Cerca stazione Trenord…", text: $query)
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
                    if store.stations.isEmpty {
                        // Catalogo non ancora scaricato: diciamolo invece di una lista vuota.
                        if catalogFailed {
                            HStack {
                                Label("Stazioni Trenord non disponibili.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Riprova") { Task { await loadCatalog() } }
                                    .buttonStyle(.borderless)
                            }
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Caricamento stazioni Trenord…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(suggestions, id: \.self) { name in
                        Button { onSelect(name) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "building.columns").foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                                Text(name).foregroundColor(.primary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
            .task { await loadCatalog() }
            .onAppear { focused = true }
        }
        .modalKeyboardSafe()
    }

    private func loadCatalog() async {
        catalogFailed = false
        await store.refreshIfNeeded()
        catalogFailed = store.stations.isEmpty
    }
}

#Preview {
    NavigationStack { TrenordBigliettiView() }
}
