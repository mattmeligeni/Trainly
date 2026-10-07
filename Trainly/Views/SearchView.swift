//
//  SearchView.swift
//  Trainly
//
//  Created by Mattia Meligeni on 12/07/2026.
//

internal import SwiftUI

enum vector: String, CaseIterable, Identifiable {
    case trenitalia = "Trenitalia"
    case italo = "Italo"
    case trenord = "Trenord"
    
    var id: String { self.rawValue }
}

struct SearchView: View {

    @State private var selectedVector: vector = .trenitalia
    @State private var searchText: String = ""
    @State private var searchTrain: String = ""

    @EnvironmentObject private var router: AppRouter
    @AppStorage("defaultVector") private var defaultVector: String = "Trenitalia"
    @StateObject private var recentTrains = RecentTrainsStore()

    @State private var didApplyDefault = false
    @State private var isLoading = false
    @State private var destination: TrainDestination?
    @State private var errorMessage: String?
    @State private var suggestions: [TrainDestination] = []  // trovati su altri vettori
    @State private var choices: [TrainDestination] = [] // più corse con lo stesso numero
    @State private var showChoices = false
    @FocusState private var searchFocused: Bool

    private var canSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {

                // MARK: - Barra di ricerca in alto
                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Inserisci numero treno...", text: $searchText)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                            .submitLabel(.search)
                            .focused($searchFocused)
                            .onSubmit(search)

                        // Pulsante "X": cancella e riapre subito la tastiera.
                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                                searchFocused = true
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Selettore vettore
                    Picker("Vettore", selection: $selectedVector) {
                        ForEach(vector.allCases) { vector in
                            Text(vector.rawValue).tag(vector)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // MARK: - Contenuto centrale
                if recentTrains.recents.isEmpty {
                    emptyPrompt
                } else {
                    recentsList
                }

                // MARK: - Pulsante in basso
                Button(action: search) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isLoading ? "Ricerca..." : "Cerca")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundColor(.white)
                    .background(canSearch ? Color.blue : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSearch) // Disabilitato se la barra è vuota o durante il caricamento
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Cerca Treno")
            .navigationDestination(item: $destination) { dest in
                TrainView(
                    journey: dest.journey,
                    favorite: dest.favorite,
                    dateOptions: dest.dateOptions,
                    currentRef: dest.exactRef,
                    loadRef: { ref in
                        try? await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                            numero: ref.numero, codOrigine: ref.codOrigine,
                            timestamp: ref.timestamp, descrizione: ""))
                    },
                    disserviceCheckNumber: dest.vector == "Trenitalia" ? dest.journey.trainNumber : nil,
                    reload: {
                        // Pull-to-refresh: corsa esatta se nota, altrimenti per numero.
                        if let ref = dest.exactRef {
                            return try? await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                                numero: ref.numero, codOrigine: ref.codOrigine,
                                timestamp: ref.timestamp, descrizione: ""))
                        } else {
                            return await TrainService.reload(vector: dest.vector,
                                                             numero: dest.journey.trainNumber)
                        }
                    }
                )
            }
            .alert("Ricerca non riuscita", isPresented: errorBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Treno non trovato", isPresented: suggestionBinding) {
                ForEach(suggestions, id: \.self) { sugg in
                    Button("Cerca con \(sugg.vector)") {
                        selectedVector = vector(rawValue: sugg.vector) ?? selectedVector
                        destination = sugg
                        suggestions = []
                    }
                }
                Button("Annulla", role: .cancel) { suggestions = [] }
            } message: {
                Text(suggestionMessage)
            }
            .sheet(isPresented: $showChoices) { choicesSheet }
            .onChange(of: router.pendingSearch) { _, _ in handlePending() }
            .onChange(of: router.selectedTab) { old, tab in
                if tab == .search {
                    // Trigger affidabile quando si arriva al tab Cerca da un'altra tab.
                    handlePending()
                } else if old == .search {
                    // Uscendo dal tab Cerca azzeriamo treno e testo: così una nuova
                    // apertura da un link non resta bloccata sul treno precedente.
                    destination = nil
                    searchText = ""
                }
            }
            .onChange(of: defaultVector) { _, new in
                // Il vettore predefinito cambia effetto subito, senza riavvio.
                selectedVector = vector(rawValue: new) ?? selectedVector
            }
            .onChange(of: destination) { _, dest in
                // Quando si apre un treno, lo salviamo tra i recenti.
                if let dest { recentTrains.add(dest.recent) }
            }
            .onAppear {
                // Applica il vettore predefinito una sola volta (se non c'è una
                // ricerca in arrivo da un'altra tab).
                if !didApplyDefault {
                    didApplyDefault = true
                    if router.pendingSearch == nil {
                        selectedVector = vector(rawValue: defaultVector) ?? .trenitalia
                    }
                }
                handlePending()
            }
        }
    }

    // MARK: - Contenuto centrale

    private var emptyPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Cerca un treno")
                .font(.title3.weight(.semibold))
            Text("Inserisci il numero del treno e seleziona il vettore per vedere lo stato in tempo reale.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recenti")
                    .font(.headline)
                Spacer()
                Button("Cancella") { recentTrains.clear() }
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(recentTrains.recents) { recent in
                        Button { openRecent(recent) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(recent.line)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func openRecent(_ recent: RecentTrain) {
        searchFocused = false
        let v = vector(rawValue: recent.vector) ?? .trenitalia
        selectedVector = v
        searchText = recent.number
        performSearch(vettore: v, numero: recent.number)
    }

    /// Esegue una ricerca richiesta da un'altra tab (es. Tabellone, Infomobilità).
    private func handlePending() {
        guard let pending = router.pendingSearch else { return }
        let v = vector(rawValue: pending.vector) ?? .trenitalia
        selectedVector = v
        searchText = pending.number
        router.pendingSearch = nil

        if let exact = pending.exactRef {
            // Link infomobilità: apre esattamente quella corsa (anche di ieri),
            // senza ricostruire la ricerca né applicare il criterio "oggi".
            openExactTrenitalia(exact)
        } else {
            performSearch(vettore: v, numero: pending.number)
        }
    }

    private func openExactTrenitalia(_ ref: ExactTrenitaliaRef) {
        isLoading = true
        Task {
            let trainRef = TrenitaliaTrainRef(numero: ref.numero,
                                              codOrigine: ref.codOrigine,
                                              timestamp: ref.timestamp,
                                              descrizione: "")
            do {
                let journey = try await TrenitaliaService.journey(from: trainRef)
                // Anche dai link infomobilità mostriamo il picker se la stessa
                // corsa esiste su più giorni.
                let dates = await sameTrainDates(numero: ref.numero, origine: ref.codOrigine, including: ref)
                destination = TrainDestination(journey: journey, vector: "Trenitalia",
                                               exactRef: ref, dateOptions: dates)
            } catch {
                // Fallback alla ricerca standard sul numero.
                performSearch(vettore: .trenitalia, numero: ref.numero)
            }
            isLoading = false
        }
    }

    /// Altre date della stessa corsa (stessa origine); vuoto se è unica.
    private func sameTrainDates(numero: String, origine: String,
                                including ref: ExactTrenitaliaRef) async -> [ExactTrenitaliaRef] {
        guard let refs = try? await TrenitaliaService.cercaNumeriTreno(numero) else { return [] }
        var same = refs.filter { $0.codOrigine == origine }.map(Self.exact)
        if !same.contains(ref) { same.append(ref) }
        guard same.count > 1 else { return [] }
        return same.sorted { $0.timestamp < $1.timestamp }
    }

    // Scelta tra più corse con lo stesso numero (solo Trenitalia).
    private var choicesSheet: some View {
        NavigationStack {
            List(choices.indices, id: \.self) { i in
                let dest = choices[i]
                Button {
                    showChoices = false
                    destination = dest
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(dest.journey.origin) → \(dest.journey.destination)")
                            .font(.headline)
                            .foregroundColor(.primary)
                        if let dep = dest.journey.departure {
                            Text("Partenza \(Self.choiceFormatter.string(from: dep))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Seleziona Treno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { showChoices = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private static let choiceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var suggestionBinding: Binding<Bool> {
        Binding(
            get: { !suggestions.isEmpty },
            set: { if !$0 { suggestions = [] } }
        )
    }

    private var suggestionMessage: String {
        let list = suggestions.map(\.vector).joined(separator: "/")
        return "Treno non trovato con \(selectedVector.rawValue), ma risulta attivo con \(list). Vuoi proseguire la ricerca cambiando vettore?"
    }

    // MARK: - Azione ricerca

    private func search() {
        searchFocused = false // chiude la tastiera
        let numero = searchText.trimmingCharacters(in: .whitespaces)
        // Un secondo invio durante la ricerca ne avviava un'altra in parallelo, con due risultati in arrivo.
        guard !numero.isEmpty, !isLoading else { return }
        performSearch(vettore: selectedVector, numero: numero)
    }

    private func performSearch(vettore: vector, numero: String) {
        isLoading = true
        Task {
            do {
                if vettore == .trenitalia {
                    try await searchTrenitalia(numero: numero)
                } else {
                    let result = try await TrainService.fetch(vector: vettore.rawValue, numero: numero)
                    destination = TrainDestination(journey: result, vector: vettore.rawValue)
                }
            } catch {
                // Controllo silenzioso su TUTTI gli altri vettori.
                suggestions = await findAlternatives(numero: numero, excluding: vettore)
                if suggestions.isEmpty {
                    errorMessage = "Nessun treno trovato con il numero \(numero)."
                }
            }
            isLoading = false
        }
    }

    /// Trenitalia può restituire più corse con lo stesso numero. Se cambiano
    /// solo per data (stessa origine) apriamo quella di oggi; mostriamo la
    /// scelta solo se sono treni effettivamente diversi.
    private func searchTrenitalia(numero: String) async throws {
        let refs = try await TrenitaliaService.cercaNumeriTreno(numero)
        let groups = Dictionary(grouping: refs, by: { $0.codOrigine })

        // Una sola origine = stesso treno. Apriamo quello di oggi; se la stessa
        // corsa risulta su più giorni offriamo la scelta della data nel dettaglio
        // (probabile viaggio iniziato il giorno prima e non ancora concluso).
        if groups.count == 1 {
            let sameTrain = groups.values.first!.sorted { $0.timestamp < $1.timestamp }
            let today = TrenitaliaService.bestRef(sameTrain) ?? sameTrain[sameTrain.count - 1]
            let journey = try await TrenitaliaService.journey(from: today)
            let dates = sameTrain.count > 1 ? sameTrain.map(Self.exact) : []
            destination = TrainDestination(journey: journey, vector: "Trenitalia",
                                           exactRef: Self.exact(today), dateOptions: dates)
            return
        }

        // Origini diverse = treni davvero diversi -> scelta.
        var options: [TrainDestination] = []
        for group in groups.values {
            if let ref = TrenitaliaService.bestRef(group),
               let journey = try? await TrenitaliaService.journey(from: ref) {
                options.append(TrainDestination(journey: journey, vector: "Trenitalia"))
            }
        }

        switch options.count {
        case 0: throw TrenitaliaError.trainNotFound
        case 1: destination = options[0]
        default:
            choices = options
            showChoices = true
        }
    }

    private static func exact(_ ref: TrenitaliaTrainRef) -> ExactTrenitaliaRef {
        ExactTrenitaliaRef(codOrigine: ref.codOrigine, numero: ref.numero, timestamp: ref.timestamp)
    }

    /// Prova tutti gli altri vettori, in parallelo, e restituisce quelli che trovano il treno (nell'ordine dei
    /// vettori). Prima uno dopo l'altro: con un vettore lento l'attesa si sommava.
    private func findAlternatives(numero: String, excluding: vector) async -> [TrainDestination] {
        let altri = vector.allCases.filter { $0 != excluding }.map(\.rawValue)
        let trovati = await withTaskGroup(of: (String, TrainJourney?).self) { group in
            for v in altri {
                group.addTask { (v, await TrainService.reload(vector: v, numero: numero)) }
            }
            var risultati: [String: TrainJourney] = [:]
            for await (v, journey) in group {
                if let journey, !journey.stops.isEmpty { risultati[v] = journey }
            }
            return risultati
        }
        return altri.compactMap { v in trovati[v].map { TrainDestination(journey: $0, vector: v) } }
    }
}

// Item di navigazione: porta con sé anche il vettore per costruire il preferito.
struct TrainDestination: Hashable {
    let journey: TrainJourney
    let vector: String
    var exactRef: ExactTrenitaliaRef? = nil   // corsa esatta (link infomobilità / oggi)
    var dateOptions: [ExactTrenitaliaRef] = [] // stesse corse su più giorni (picker)

    var favorite: FavoriteTrain {
        FavoriteTrain(
            vector: vector,
            number: journey.trainNumber,
            title: journey.title,
            subtitle: "\(journey.origin) → \(journey.destination)",
            category: journey.category
        )
    }

    var recent: RecentTrain {
        RecentTrain(
            vector: vector,
            number: journey.trainNumber,
            shortName: shortName,
            origin: journey.origin,
            destination: journey.destination
        )
    }

    /// Nome breve: per Trenitalia il codice categoria (IC/FR/REG…), per gli
    /// altri il titolo già compatto ("ITALO Av 9876", "Trenord 3647").
    private var shortName: String {
        guard vector == "Trenitalia" else { return journey.title }
        let code: String
        switch journey.category {
        case "FRECCIAROSSA": code = "FR"
        case "FRECCIARGENTO": code = "FA"
        case "FRECCIABIANCA": code = "FB"
        case "INTERCITY-2": code = "IC"
        case "TRENITALIA-3": code = "REG"
        case "TRENITALIA": code = "EC"
        case "LEONARDOEXP": code = "Leonardo Express"
        default: code = ""
        }
        return code.isEmpty ? "Treno \(journey.trainNumber)" : "\(code) \(journey.trainNumber)"
    }
}


#Preview {
    SearchView()
        .environmentObject(FavoritesStore())
        .environmentObject(AppRouter())
}
