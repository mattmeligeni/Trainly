//
//  StationBoardView.swift
//  Trainly
//
//  Tabellone partenze/arrivi di una stazione (scraping RFI).
//  Al tocco di una riga si apre la ricerca del treno nel tab Cerca.
//

internal import SwiftUI

struct StationBoardView: View {

    let station: RFIStation

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 46

    @State private var arrivals = false   // false = Partenze, true = Arrivi
    @State private var trains: [RFITrain] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedTrain: TrainRequest?
    /// Segmento a cui appartengono `trains` (nil = ancora nessun dato).
    @State private var loadedArrivals: Bool?
    @State private var lastUpdate: Date?
    /// Contatore dei caricamenti: una risposta vecchia non sovrascrive una nuova.
    @State private var generation = 0
    @State private var retryTask: Task<Void, Never>?

    /// Intervallo dell'aggiornamento automatico.
    private let refreshInterval: TimeInterval = 60

    /// Chiave del task: cambia con il segmento e quando l'app va in background,
    /// così il ciclo di aggiornamento si ferma e riparte da solo.
    private struct RefreshKey: Equatable {
        let arrivals: Bool
        let active: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // Etichetta letta da VoiceOver (lo stile segmentato non la mostra).
            Picker("Tipo di tabellone", selection: $arrivals) {
                Text("Partenze").tag(false)
                Text("Arrivi").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 6)

            statusLine
                .padding(.horizontal)
                .padding(.bottom, 6)

            content
        }
        .navigationTitle(station.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Al cambio segmento svuota subito e ricarica; il pull-to-refresh no.
        // Poi aggiorna ogni 60 s finché la vista è visibile e l'app è attiva.
        .task(id: RefreshKey(arrivals: arrivals, active: scenePhase == .active)) {
            await autoRefreshLoop()
        }
        .refreshable { await load() }
        .onDisappear { retryTask?.cancel() }
        // Apre il treno nella stessa tab: tornando indietro si resta sul tabellone.
        .navigationDestination(item: $selectedTrain) { request in
            TrainLoaderView(request: request)
        }
    }

    // MARK: - Stato aggiornamento

    /// "Aggiornato alle HH:mm", con indicatore durante il refresh e avviso se l'ultimo è fallito.
    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if let lastUpdate, loadedArrivals == arrivals {
                Text("Aggiornato alle \(Self.timeFormatter.string(from: lastUpdate))")
            } else if isLoading {
                Text("Caricamento…")
            }
            if isLoading && !trains.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Aggiornamento in corso")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// Orari del tabellone in ora italiana, indipendentemente dal fuso del dispositivo.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Contenuto

    // Sempre una List, così il pull-to-refresh funziona anche su errore/vuoto.
    private var content: some View {
        List {
            if trains.isEmpty {
                if isLoading || loadedArrivals != arrivals && errorMessage == nil {
                    // Lo spinner è nell'overlay.
                    EmptyView()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Tabellone non disponibile", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        retryButton
                    }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView(arrivals ? "Nessun arrivo previsto" : "Nessuna partenza prevista",
                                           systemImage: "tram")
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            } else {
                // Dati vecchi tenuti a schermo: si avvisa solo che l'ultimo refresh è fallito.
                if let errorMessage {
                    staleBanner(errorMessage)
                }
                ForEach(trains) { row($0) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading && trains.isEmpty {
                ProgressView()
            }
        }
    }

    private var retryButton: some View {
        Button("Riprova") {
            retryTask?.cancel()
            retryTask = Task { await load() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading)
    }

    private func staleBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.boardWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aggiornamento non riuscito")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Riprova") {
                retryTask?.cancel()
                retryTask = Task { await load() }
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Caricamento

    private func autoRefreshLoop() async {
        guard scenePhase == .active else { return }
        // Cambio segmento: i treni dell'altro segmento non devono restare a schermo.
        if loadedArrivals != arrivals {
            trains = []
            errorMessage = nil
            lastUpdate = nil
        }
        // Se i dati sono ancora freschi (es. ritorno dal dettaglio treno)
        // si aspetta il resto del minuto invece di ricaricare subito.
        var wait: TimeInterval = 0
        if loadedArrivals == arrivals, errorMessage == nil, let lastUpdate {
            wait = max(0, refreshInterval - Date.now.timeIntervalSince(lastUpdate))
        }
        while !Task.isCancelled {
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
            }
            await load()
            wait = refreshInterval
        }
    }

    private func load() async {
        let wanted = arrivals
        generation += 1
        let current = generation
        isLoading = true
        defer {
            // Solo l'ultimo caricamento avviato spegne l'indicatore.
            if current == generation { isLoading = false }
        }
        do {
            let result = try await RFIService.getTrains(placeId: station.code, arrivals: wanted)
            // Se nel frattempo si è cambiato segmento, questo task è stato
            // cancellato: non tocchiamo lo stato del nuovo caricamento.
            if Task.isCancelled { return }
            // Anche il pull-to-refresh (non cancellato dal cambio segmento) o una
            // risposta superata da una più recente vengono scartati.
            guard current == generation, wanted == arrivals else { return }
            trains = result
            loadedArrivals = wanted
            lastUpdate = .now
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }   // errore dovuto alla cancellazione: ignora
            guard current == generation, wanted == arrivals else { return }
            // I treni già mostrati restano: si segnala solo l'errore.
            errorMessage = Self.message(for: error)
        }
    }

    /// Messaggio d'errore leggibile: offline, server in errore o formato cambiato.
    private static func message(for error: Error) -> String {
        if let rfi = error as? RFIError, let text = rfi.errorDescription {
            return text
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff:
                return "Sei offline. Controlla la connessione e riprova."
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Il server RFI non risponde. Riprova tra poco."
            default:
                break
            }
        }
        return "Impossibile caricare il tabellone."
    }

    // MARK: - Riga treno

    private func row(_ t: RFITrain) -> some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        // Con testo molto grande orario e binario vanno sotto, così la destinazione non si tronca.
        let layout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        return Button {
            selectedTrain = .vectorNumber(vector: t.searchVector, number: t.treno)
        } label: {
            layout {
                HStack(alignment: .center, spacing: 12) {
                    logo(t)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.badgeLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(isAX ? nil : 1)
                        Text(destinationLine(t))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(isAX ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                        numberBadge(t.treno)
                        if let stops = stopsLine(t) {
                            Text(stops)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(isAX ? nil : 2)
                        }
                        if !t.informazioni.isEmpty {
                            Text(StationName.sentence(t.informazioni))
                                .font(.caption)
                                .foregroundStyle(Color.boardWarning)
                                .lineLimit(isAX ? nil : 2)
                        }
                    }
                }

                if !isAX { Spacer(minLength: 8) }

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: isAX ? .leading : .trailing, spacing: 4) {
                        Text(t.orario)
                            .font(.headline.monospacedDigit())
                        trailingInfo(t)
                    }

                    if t.inPartenza {
                        RailroadBlinker(label: arrivals ? "In arrivo" : "In partenza")
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver: una sola frase per riga invece di tanti pezzi slegati.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(t))
        .accessibilityHint("Apre il dettaglio del treno")
        .accessibilityAddTraits(.isButton)
    }

    /// "per Torino Porta Nuova" in Partenze, "da Bergamo" in Arrivi.
    private func destinationLine(_ t: RFITrain) -> String {
        "\(arrivals ? "da" : "per") \(StationName.display(t.destinazione))"
    }

    /// Fermate successive in forma leggibile (le fornisce RFI solo in Partenze).
    private func stopsLine(_ t: RFITrain) -> String? {
        var text = t.fermate.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.uppercased().hasPrefix("FERMA A:") {
            text = String(text.dropFirst("FERMA A:".count)).trimmingCharacters(in: .whitespaces)
        }
        return "Ferma a: " + StationName.display(text)
    }

    private func accessibilityText(_ t: RFITrain) -> String {
        var parts = [
            "\(t.badgeLabel) \(t.treno)",
            destinationLine(t),
            "\(arrivals ? "arrivo" : "partenza") alle \(t.orario)",
        ]
        if let delay = delayDescription(t) { parts.append(delay.spoken) }
        let platform = t.binario.trimmingCharacters(in: .whitespaces)
        if !platform.isEmpty { parts.append("binario \(platform)") }
        if t.inPartenza { parts.append(arrivals ? "in arrivo" : "in partenza") }
        if !t.informazioni.isEmpty { parts.append(StationName.sentence(t.informazioni)) }
        if let stops = stopsLine(t) { parts.append(stops) }
        return parts.joined(separator: ", ")
    }

    private func numberBadge(_ number: String) -> some View {
        Text(number)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(.primary)
            .background(Color(.systemGray5))
            .clipShape(Capsule())
    }

    private func logo(_ t: RFITrain) -> some View {
        Group {
            if let name = t.logoImageName, UIImage(named: name) != nil {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "tram.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: logoSize, height: logoSize)
        .background(Color.logoTile)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Testo breve, colore e frase per VoiceOver dello stato di puntualità.
    private struct DelayInfo {
        let text: String
        let spoken: String
        let color: Color
    }

    private func delayDescription(_ t: RFITrain) -> DelayInfo? {
        if let delay = t.delayMinutes {
            if delay > 0 {
                return DelayInfo(text: "+\(delay) min",
                                 spoken: delay == 1 ? "1 minuto di ritardo" : "\(delay) minuti di ritardo",
                                 color: .boardLate)
            } else if delay < 0 {
                let early = -delay
                return DelayInfo(text: "−\(early) min",
                                 spoken: early == 1 ? "1 minuto di anticipo" : "\(early) minuti di anticipo",
                                 color: .boardOnTime)
            } else {
                return DelayInfo(text: "in orario", spoken: "in orario", color: .boardOnTime)
            }
        }
        // Testo non numerico (es. "RITARDO"); cella vuota = nessuna informazione.
        if let status = t.statusText {
            let text = StationName.sentence(status)
            return DelayInfo(text: text, spoken: text, color: .boardWarning)
        }
        return nil
    }

    @ViewBuilder
    private func trailingInfo(_ t: RFITrain) -> some View {
        HStack(spacing: 6) {
            if let info = delayDescription(t) {
                Text(info.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(info.color)
            }

            if !t.binario.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Bin. \(t.binario)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Colori ritardo

// Varianti più scure in modalità chiara: `.green`/`.orange` su bianco sono sotto 3:1.
private extension Color {
    static let boardLate = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.75, green: 0.10, blue: 0.10, alpha: 1)
    })
    static let boardOnTime = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.10, green: 0.45, blue: 0.20, alpha: 1)
    })
    static let boardWarning = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.65, green: 0.35, blue: 0.0, alpha: 1)
    })
}

// MARK: - Luce lampeggiante (passaggio a livello)

/// Due luci rosse che si alternano in modo netto, come un passaggio a livello.
struct RailroadBlinker: View {
    /// "In arrivo" o "In partenza", secondo il tabellone.
    var label: String = "In arrivo"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let period = 0.45

    var body: some View {
        Group {
            if reduceMotion {
                // Riduci movimento: luci fisse, nessun lampeggio.
                HStack(spacing: 4) {
                    dot(on: true)
                    dot(on: true)
                }
            } else {
                // Partenza da una data fissa (non `.now`): tutti i lampeggianti restano
                // sincronizzati anche se compaiono in momenti diversi.
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: period)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / period) % 2 == 0
                    HStack(spacing: 4) {
                        dot(on: on)
                        dot(on: !on)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func dot(on: Bool) -> some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.12)
    }
}

#Preview {
    NavigationStack {
        StationBoardView(station: RFIStation(name: "MILANO CENTRALE", code: "1728"))
            .environmentObject(AppRouter())
    }
}
