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

    @State private var origin: String?          // nome esatto della stazione Trenord
    @State private var destination: String?
    @State private var date = Date()

    @State private var result: TrenordSearchResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searched = false
    @State private var picking: Field?
    @State private var showResults = false

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

            Section("Quando") {
                DatePicker("Partenza", selection: $date, in: Date()...)
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

            if let errorMessage, !isLoading {
                Section { Text(errorMessage).foregroundColor(.secondary) }
            }

            Section {
                Text("Ricerca di orari e prezzi dei treni regionali Trenord. Per l'acquisto usa i canali ufficiali Trenord.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Biglietti Trenord")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !searched { date = Date() } }
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
    }

    private func reset() {
        origin = nil
        destination = nil
        result = nil
        searched = false
        errorMessage = nil
    }

    private func search() {
        guard let o = origin, let d = destination else { return }
        isLoading = true
        errorMessage = nil
        searched = true
        let from = BigliettiView.hhmm(date)
        let searchDate = date
        Task {
            let r = await TrenordTicketService.firstPage(
                originName: o, destName: d, date: searchDate, fromTime: from)
            result = r
            if let r, !r.solutions.isEmpty {
                showResults = true
            } else {
                errorMessage = "Nessuna soluzione Trenord per questa tratta."
            }
            isLoading = false
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
    @State private var noMore = false

    init(result: TrenordSearchResult) {
        self.result = result
        _solutions = State(initialValue: result.solutions)
        _lastTime = State(initialValue: result.lastDepTime)
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
                Section { Text("Nessuna soluzione con questi filtri.").foregroundColor(.secondary) }
            } else {
                Section {
                    ForEach(list) { sol in
                        NavigationLink {
                            SolutionDetailView(solution: sol)
                        } label: {
                            SolutionRow(solution: sol)
                        }
                    }
                }
            }

            if !noMore, !solutions.isEmpty {
                Section {
                    Button(action: loadMore) {
                        HStack {
                            if loadingMore { ProgressView().padding(.trailing, 4) }
                            Text(loadingMore ? "Caricamento…" : "Mostra successivi")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(loadingMore)
                }
            }
        }
        .navigationTitle("Soluzioni Trenord")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadMore() {
        guard let last = lastTime, !loadingMore else { return }
        loadingMore = true
        Task {
            let from = TrenordTime.nextMinute(last)
            let (more, newLast) = await TrenordTicketService.page(
                trenordOrigin: result.trenordOrigin, trenordDestination: result.trenordDestination,
                date: result.date, fromTime: from)
            let existing = Set(solutions.map(\.id))
            let fresh = more.filter { !existing.contains($0.id) }
            if fresh.isEmpty || newLast == nil {
                noMore = true
            } else {
                solutions.append(contentsOf: fresh)
                lastTime = newLast
            }
            loadingMore = false
        }
    }
}

// MARK: - Ricerca stazione Trenord (sheet)

struct TrenordStationSearchView: View {
    let title: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] { TrenordStationsStore.shared.suggest(query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Cerca stazione Trenord…", text: $query)
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
                    ForEach(suggestions, id: \.self) { name in
                        Button { onSelect(name) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "building.columns").foregroundStyle(.tint)
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
            .task { await TrenordStationsStore.shared.refreshIfNeeded() }
            .onAppear { focused = true }
        }
        .modalKeyboardSafe()
    }
}

#Preview {
    NavigationStack { TrenordBigliettiView() }
}
