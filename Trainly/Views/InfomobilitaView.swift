//
//  InfomobilitaView.swift
//  Trainly
//
//  Avvisi di infomobilità Trenitalia. Dati dalla cache condivisa
//  (InfomobilitaStore, 5 minuti); pull-to-refresh forza il download.
//

internal import SwiftUI

struct InfomobilitaView: View {

    @EnvironmentObject private var router: AppRouter
    @Environment(\.openURL) private var openURL

    @State private var items: [InfoItem] = []
    @State private var updatedAt: Date?
    @State private var isLoading = true
    @State private var didLoadOnce = false
    @State private var errorMessage: String?
    @State private var expandedIDs: Set<String> = []
    @State private var scrollTarget: String?
    @State private var query = ""
    @State private var missingNoticeMessage: String?
    @State private var retryTask: Task<Void, Never>?
    // Solo l'ultimo caricamento scrive lo stato: risultati vecchi non sovrascrivono i nuovi.
    @State private var loadGeneration = 0

    /// Avvisi filtrati dalla ricerca, con quelli "In evidenza" in cima
    /// (mantenendo l'ordine del sito all'interno dei due gruppi).
    private var displayedItems: [InfoItem] {
        let filtered = query.isEmpty ? items : items.filter { $0.matches(query) }
        return filtered.filter(\.isHighlighted) + filtered.filter { !$0.isHighlighted }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !items.isEmpty { statusSection }
                ForEach(displayedItems) { item in
                    Section {
                        DisclosureGroup(isExpanded: expandedBinding(item.id)) {
                            itemBody(item)
                        } label: {
                            itemHeader(item)
                        }
                    }
                    .id(item.id)
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
        .overlay { emptyState }
        .navigationTitle("Infomobilità Trenitalia")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Cerca negli avvisi")
        .refreshable { await load(force: true) }
        // .task con la cache a TTL: tornando da un treno non si riscarica e
        // gli avvisi aperti e lo scroll restano dove erano.
        .task { await load(force: false) }
        // Arrivo da "Maggiori info sul disservizio" con la vista già aperta.
        .onChange(of: router.pendingInfoTrain) { _, pending in
            guard pending != nil else { return }
            retry(force: false)
        }
        .onDisappear { retryTask?.cancel() }
        // Treno aperto nella stessa tab: si torna indietro all'infomobilità.
        .navigationDestination(item: $router.infomobilitaTrain) { request in
            TrainLoaderView(request: request)
        }
        .alert("Avviso non più presente",
               isPresented: Binding(get: { missingNoticeMessage != nil },
                                    set: { if !$0 { missingNoticeMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(missingNoticeMessage ?? "")
        }
    }

    // MARK: - Stato (aggiornamento, errori, vuoto)

    /// "Aggiornato alle HH:mm" oppure, se l'ultimo refresh è fallito,
    /// l'errore con Riprova: gli avvisi già caricati restano visibili.
    private var statusSection: some View {
        Section {
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(errorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                    if let updatedAt {
                        Text("Mostro gli avvisi delle \(Self.timeString(updatedAt)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Riprova") { retry(force: true) }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            } else if let updatedAt {
                Label("Aggiornato alle \(Self.timeString(updatedAt))", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Infomobilità non disponibile", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Riprova") { retry(force: true) }
                        .buttonStyle(.borderedProminent)
                }
            } else if didLoadOnce {
                ContentUnavailableView("Nessun avviso",
                                       systemImage: "checkmark.circle",
                                       description: Text("Al momento non ci sono avvisi di infomobilità."))
            }
        } else if displayedItems.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: - Header / body

    private func itemHeader(_ item: InfoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let style = colorStyle(item.color)
            Image(systemName: style.symbol)
                .font(.subheadline)
                .foregroundStyle(style.color)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)   // la gravità è letta dal testo qui sotto

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                // Gravità anche come testo: non affidata al solo colore.
                Text(item.date.isEmpty ? item.severity.label : "\(item.severity.label) · \(item.date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.tags) { tagBadge($0) }
                    }
                }
            }
        }
        // VoiceOver: un solo elemento invece di simbolo, titolo e data a pezzi.
        .accessibilityElement(children: .combine)
    }

    private func itemBody(_ item: InfoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.text.characters.isEmpty {
                Text(item.text)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineSpacing(2)
            }
            ForEach(item.links) { link in
                linkView(link)
            }
        }
        .padding(.top, 4)
    }

    private func tagBadge(_ tag: InfoTag) -> some View {
        Text(tag.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(tag.highlighted ? .black : .secondary)
            .background(tag.highlighted ? Color.yellow : Color(.systemGray5))
            .clipShape(Capsule())
    }

    /// Colore + simbolo della left-bar del sito.
    private func colorStyle(_ color: String?) -> (color: Color, symbol: String) {
        switch color {
        case "red": return (.red, "exclamationmark.triangle.fill")
        case "orange": return (.orange, "message.fill")
        case "green": return (.green, "clock.fill")
        default: return (.secondary, "info.circle.fill")
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { if $0 { expandedIDs.insert(id) } else { expandedIDs.remove(id) } }
        )
    }

    // MARK: - Link

    @ViewBuilder
    private func linkView(_ link: InfoLink) -> some View {
        if let ref = link.trainRef {
            // Corsa esatta -> apre il treno nella stessa tab.
            Button {
                router.infomobilitaTrain = .exactTrenitalia(ref)
            } label: {
                linkLabel(link, icon: "tram.fill")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Apre il treno \(ref.numero)")
        } else if link.isGenericSearch {
            // Link "cerca treno" generico -> apre il tab Cerca dell'app.
            Button {
                router.openSearchTab()
            } label: {
                linkLabel(link, icon: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Apre la ricerca treni")
        } else if let url = link.url {
            Button {
                openURL(url)
            } label: {
                linkLabel(link, icon: iconName(for: url))
            }
            .buttonStyle(.plain)
            .accessibilityHint(url.pathExtension.lowercased() == "pdf" ? "Apre il documento PDF" : "Apre nel browser")
        } else {
            linkLabel(link, icon: "link")
        }
    }

    private func linkLabel(_ link: InfoLink, icon: String) -> some View {
        HStack(spacing: 8) {
            Text("(\(link.number))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tint)
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(link.label)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func iconName(for url: URL) -> String {
        url.pathExtension.lowercased() == "pdf" ? "doc.text" : "arrow.up.right.square"
    }

    // MARK: - Caricamento

    /// Riprova / nuovo treno da evidenziare: annulla il tentativo precedente.
    private func retry(force: Bool) {
        retryTask?.cancel()
        retryTask = Task { await load(force: force) }
    }

    private func load(force: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let store = InfomobilitaStore.shared

        // Cache già pronta (es. dal banner del treno): mostrata subito.
        if items.isEmpty, let cached = store.items {
            items = cached
            updatedAt = store.fetchedAt
        }
        isLoading = true
        do {
            let fetched = try await store.load(force: force)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            items = fetched
            updatedAt = store.fetchedAt
            errorMessage = nil
            // Restano aperti solo gli avvisi ancora presenti (id stabili dall'HTML).
            expandedIDs.formIntersection(fetched.map(\.id))
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // Gli avvisi già mostrati restano: si segnala solo l'errore.
            errorMessage = Self.message(for: error)
        }
        isLoading = false
        didLoadOnce = true
        highlightPendingTrain()
    }

    /// Se si arriva da "Maggiori info sul disservizio", apre e scorre al box.
    private func highlightPendingTrain() {
        guard let pending = router.pendingInfoTrain else { return }
        // Azzerato sempre dopo il primo caricamento, trovato o no: altrimenti
        // resterebbe appeso e scatterebbe a un'apertura successiva.
        router.pendingInfoTrain = nil
        guard !items.isEmpty else { return }   // l'errore è già a schermo
        guard let target = items.first(where: {
            $0.mentions(train: pending.number, origin: pending.origin, day: pending.day)
        }) else {
            missingNoticeMessage = "L'avviso sul treno \(pending.number) non è più presente in infomobilità: il disservizio potrebbe essere terminato."
            return
        }
        query = ""   // l'avviso deve essere visibile anche con una ricerca attiva
        expandedIDs.insert(target.id)
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            scrollTarget = target.id
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(urlError.code) {
            return "Nessuna connessione a Internet."
        }
        if case InfomobilitaError.parsing = error {
            return "La pagina di Trenitalia ha un formato inatteso."
        }
        return "Impossibile caricare l'infomobilità."
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }
}

#Preview {
    NavigationStack {
        InfomobilitaView()
            .environmentObject(AppRouter())
    }
}
