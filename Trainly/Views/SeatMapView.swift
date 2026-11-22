//
//  SeatMapView.swift
//  Trainly
//
//  Mappa dei posti di un treno Trenitalia o Italo tra due fermate. Di default
//  dalla prima fermata ancora acquistabile (tutta la tratta se il treno non è
//  partito) all'ultima. Mostra tutte le classi insieme (composizione completa),
//  carrozza per carrozza, man mano che si caricano.
//

internal import SwiftUI

struct SeatMapView: View {

    let carrier: SeatMapCarrier
    let trainNumber: String
    let trainLabel: String
    /// Fermate cercabili (Trenitalia: con codice stazione).
    let stops: [TrainStop]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var fromIndex: Int
    @State private var toIndex: Int
    @State private var map: FullSeatMap?
    @State private var progress: (loaded: Int, total: Int)?
    @State private var error: SeatMapError?
    @State private var isLoading = true
    @State private var selectedWagonId: String?
    @State private var reloadToken = 0
    @State private var zoom: CGFloat = 1

    /// La vendita (e quindi la mappa) chiude qualche minuto prima della partenza
    /// programmata dalla fermata scelta.
    private static let saleClosesBefore: TimeInterval = 5 * 60

    init(carrier: SeatMapCarrier = .trenitalia, trainNumber: String, trainLabel: String, stops: [TrainStop]) {
        self.carrier = carrier
        self.trainNumber = trainNumber
        self.trainLabel = trainLabel
        self.stops = stops
        let limit = Date().addingTimeInterval(Self.saleClosesBefore)
        let firstBookable = stops.indices.first { i in
            i < stops.count - 1 && (stops[i].scheduledDeparture.map { $0 > limit } ?? false)
        }
        _fromIndex = State(initialValue: firstBookable ?? 0)
        _toIndex = State(initialValue: max(0, stops.count - 1))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                layout
                    .padding()
                    .frame(maxWidth: sizeClass == .regular ? 1000 : 560)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Posti · \(trainLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { reloadToken += 1 } label: {
                        Label("Aggiorna", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task(id: "\(fromIndex)-\(toIndex)-\(reloadToken)") { await load() }
        }
    }

    // MARK: - Tratta

    private var routeCard: some View {
        VStack(spacing: 0) {
            Picker("Da", selection: $fromIndex) {
                ForEach(departureIndices, id: \.self) { i in
                    Text(stopLabel(i, departure: true)).tag(i)
                }
            }
            Divider()
            Picker("A", selection: $toIndex) {
                ForEach(arrivalIndices, id: \.self) { i in
                    Text(stopLabel(i, departure: false)).tag(i)
                }
            }
        }
        .pickerStyle(.menu)
        // Una richiesta alla volta: la sessione ha un solo carrello.
        .disabled(isLoading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: fromIndex) { _, newValue in
            if toIndex <= newValue { toIndex = stops.count - 1 }
        }
    }

    private var departureIndices: [Int] {
        stops.indices.filter { $0 < stops.count - 1 && stops[$0].scheduledDeparture != nil }
    }

    private var arrivalIndices: [Int] {
        stops.indices.filter { $0 > fromIndex }
    }

    private func isBookable(_ index: Int) -> Bool {
        stops[index].scheduledDeparture.map { $0 > Date().addingTimeInterval(Self.saleClosesBefore) } ?? false
    }

    private func stopLabel(_ index: Int, departure: Bool) -> String {
        let stop = stops[index]
        let time = departure ? (stop.scheduledDeparture ?? stop.scheduledArrival) : (stop.scheduledArrival ?? stop.scheduledDeparture)
        var label = time.map { "\(stop.stationName) · \(Self.hm.string(from: $0))" } ?? stop.stationName
        if departure, !isBookable(index) { label += " · partito" }
        return label
    }

    /// Prima fermata dopo quella scelta da cui la vendita è ancora aperta
    /// (sull'orario programmato, come lefrecce e Italo).
    private var nextBookableIndex: Int? {
        departureIndices.first { $0 > fromIndex && isBookable($0) }
    }

    // MARK: - Contenuto

    /// Larghezza regolare (schermo interno di iPhone Duo, iPad) con le carrozze:
    /// comandi a sinistra, pianta a destra, separate dalla piega. Altrimenti una
    /// colonna, con la striscia delle carrozze fissata in alto mentre si scorre.
    @ViewBuilder
    private var layout: some View {
        if let map, !map.wagons.isEmpty, sizeClass == .regular {
            DuoTwoColumns(spacing: 16) {
                routeCard
                summary(map)
                wagonStrip(map)
                legend
            } trailing: {
                wagonMap(map)
            }
        } else if let map, !map.wagons.isEmpty {
            LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                routeCard
                summary(map)
                Section {
                    wagonMap(map)
                    legend
                } header: {
                    wagonStrip(map)
                        .padding(.vertical, 6)
                        .background(Color(.systemGroupedBackground))
                }
            }
        } else {
            VStack(spacing: 16) {
                routeCard
                statusView
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let error, !isLoading {
            failureView(error)
        } else if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text(progressText ?? "Carico i posti di tutte le classi…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if let map {
            summary(map)
            Text(map.selectionAllowed
                 ? "Nessuna carrozza disponibile per questa tratta."
                 : "La scelta del posto non è disponibile: i posti vengono assegnati automaticamente.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
        }
    }

    private var progressText: String? {
        guard let progress, progress.total > 1 else { return nil }
        return "Classi caricate: \(progress.loaded) di \(progress.total)…"
    }

    private func failureView(_ error: SeatMapError) -> some View {
        let (icon, title, message) = describe(error)
        return VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .notSaleable(let status) = error, status != "SOLD_OUT", let next = nextBookableIndex {
                Button("Dalla prossima fermata: \(stops[next].stationName)") {
                    fromIndex = next
                }
                .buttonStyle(.borderedProminent)
            } else if error == .network {
                Button("Riprova") { reloadToken += 1 }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal)
    }

    private func describe(_ error: SeatMapError) -> (String, String, String) {
        let station = stops[fromIndex].stationName
        switch error {
        case .notSaleable("SOLD_OUT"):
            return ("person.3.fill", "Treno esaurito",
                    "Non ci sono più posti in vendita su questa tratta.")
        case .notSaleable("INHIBITED"):
            return ("nosign", "Vendita sospesa",
                    "La vendita è sospesa per questo treno su questa tratta.")
        case .notSaleable:
            return ("clock.badge.xmark", "Posti non consultabili",
                    isBookable(fromIndex)
                        ? "La vendita non è aperta su questa tratta."
                        : "Il treno è già partito da \(station) o parte a breve: la vendita per questa tratta è chiusa. Scegli una fermata successiva.")
        case .noSeatMap:
            return ("chair", "Posti non assegnati",
                    "Su questo treno non è prevista la scelta del posto.")
        case .trainNotFound:
            return ("magnifyingglass", "Treno non trovato",
                    "Il treno non compare nella ricerca \(carrier == .italo ? "Italo" : "Trenitalia") per questa tratta.")
        case .stationNotSupported:
            return ("mappin.slash", "Fermata non supportata",
                    "Non è possibile cercare i posti da questa fermata.")
        case .network:
            return ("wifi.exclamationmark", "Impossibile caricare la mappa",
                    "Controlla la connessione e riprova.")
        }
    }

    private func summary(_ map: FullSeatMap) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(map.freeCount)")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.green)
                Text("posti liberi su \(map.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView() }
            }
            .accessibilityElement(children: .combine)
            if isLoading, let progressText {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !map.soldOutClasses.isEmpty {
                Text("Esaurite: " + map.soldOutClasses.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !map.selectionAllowed {
                Label("La scelta del posto non è disponibile: i posti vengono assegnati automaticamente.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func wagonStrip(_ map: FullSeatMap) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(map.wagons) { item in
                    let isSelected = item.id == (selectedWagonId ?? map.wagons.first?.id)
                    Button {
                        selectedWagonId = item.id
                    } label: {
                        VStack(spacing: 2) {
                            Text("Carrozza \(item.id)")
                                .font(.subheadline.weight(.semibold))
                            Text(item.className)
                                .font(.caption2)
                                .lineLimit(1)
                            Text(item.wagon.freeCount == 1 ? "1 libero" : "\(item.wagon.freeCount) liberi")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(item.wagon.freeCount > 0 ? Color.green : Color.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minWidth: 96, minHeight: 44)
                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Carrozza \(item.id), \(item.className), \(item.wagon.freeCount) posti liberi su \(item.wagon.totalCount)")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    @ViewBuilder
    private func wagonMap(_ map: FullSeatMap) -> some View {
        if let item = map.wagons.first(where: { $0.id == selectedWagonId }) ?? map.wagons.first {
            ZoomableWagon(wagon: item.wagon, zoom: zoom)
                .accessibilityLabel("Carrozza \(item.id), \(item.className): \(item.wagon.freeCount) posti liberi su \(item.wagon.totalCount)")
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color.green).frame(width: 14, height: 14)
                Text("Libero")
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(.systemGray2), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                Text("Occupato")
            }
            Spacer()
            // Ingrandimento: le etichette dei posti diventano leggibili.
            Button { zoom = max(1, zoom - 0.5) } label: {
                Label("Riduci", systemImage: "minus.magnifyingglass")
            }
            .disabled(zoom <= 1)
            Button { zoom = min(2.5, zoom + 0.5) } label: {
                Label("Ingrandisci", systemImage: "plus.magnifyingglass")
            }
            .disabled(zoom >= 2.5)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Caricamento

    private func load() async {
        guard stops.indices.contains(fromIndex), stops.indices.contains(toIndex), fromIndex < toIndex else { return }
        isLoading = true
        error = nil
        map = nil
        progress = nil
        let from = stops[fromIndex], to = stops[toIndex]
        let update: @MainActor (FullSeatMap, Int, Int) -> Void = { partial, loaded, total in
            guard !Task.isCancelled else { return }
            map = partial
            progress = (loaded, total)
            if !partial.wagons.contains(where: { $0.id == selectedWagonId }) {
                selectedWagonId = partial.wagons.first?.id
            }
        }
        do {
            let result: FullSeatMap
            switch carrier {
            case .trenitalia:
                let context = try await SeatMapService.locate(trainNumber: trainNumber, from: from, to: to)
                result = try await SeatMapService.fullSeatMap(context, onProgress: update)
            case .italo:
                result = try await ItaloSeatMapService.fullSeatMap(trainNumber: trainNumber, from: from, to: to,
                                                                   onProgress: update)
            }
            guard !Task.isCancelled else { return }
            update(result, progress?.total ?? 1, progress?.total ?? 1)
            map = result
        } catch is CancellationError {
            return
        } catch let seatError as SeatMapError {
            guard !Task.isCancelled else { return }
            map = nil
            error = seatError
        } catch {
            guard !Task.isCancelled else { return }
            map = nil
            self.error = .network
        }
        isLoading = false
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Carrozza con ingrandimento

/// Pianta della carrozza alla larghezza disponibile (max 420 pt); ingrandita,
/// scorre anche in orizzontale.
private struct ZoomableWagon: View {
    let wagon: SeatWagon
    let zoom: CGFloat
    @State private var available: CGFloat = 360

    var body: some View {
        let base = min(available, 420)
        Group {
            if zoom > 1 {
                ScrollView(.horizontal) {
                    WagonSeatMap(wagon: wagon)
                        .frame(width: base * zoom)
                }
            } else {
                WagonSeatMap(wagon: wagon)
                    .frame(width: base)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = max(200, $0) }
    }
}

// MARK: - Disegno della carrozza

/// Pianta della carrozza disegnata con le coordinate fornite dal vettore
/// (sistema di riferimento = dimensioni dell'immagine della carrozza).
struct WagonSeatMap: View {
    let wagon: SeatWagon

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var canvasSize: CGSize {
        let w = wagon.image?.width ?? 0, h = wagon.image?.height ?? 0
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : CGSize(width: 384, height: 1720)
    }

    var body: some View {
        Canvas { context, size in
            let scale = size.width / canvasSize.width

            // Sagoma della carrozza.
            let outline = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 24 * scale)
            context.fill(outline, with: .color(Color(.secondarySystemGroupedBackground)))
            context.stroke(outline, with: .color(Color(.separator)), lineWidth: 1)

            for icon in wagon.additionalIcons ?? [] {
                drawIcon(icon, in: &context, scale: scale)
            }
            for seat in wagon.drawableSeats {
                drawSeat(seat, in: &context, scale: scale)
            }
        }
        .aspectRatio(canvasSize.width / canvasSize.height, contentMode: .fit)
        // Un elemento VoiceOver per posto, nella sua posizione sulla pianta.
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            GeometryReader { geo in
                let scale = geo.size.width / canvasSize.width
                ForEach(Array(wagon.drawableSeats.enumerated()), id: \.offset) { _, seat in
                    if let frame = rect(seat.image, scale: scale) {
                        Rectangle()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityLabel("Posto \(seat.label ?? seat.number ?? ""), \(seat.available == true ? "libero" : "occupato")")
                    }
                }
            }
        }
    }

    private func rect(_ shape: SeatShape?, scale: CGFloat) -> CGRect? {
        guard let shape, let x = shape.x, let y = shape.y, let w = shape.width, let h = shape.height,
              w > 0, h > 0 else { return nil }
        return CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
    }

    private func drawIcon(_ icon: SeatShape, in context: inout GraphicsContext, scale: CGFloat) {
        let kind = SeatIconKind(id: icon.id)
        guard kind != .hidden, let frame = rect(icon, scale: scale) else { return }
        let box = Path(roundedRect: frame.insetBy(dx: 2 * scale, dy: 2 * scale), cornerRadius: 6 * scale)
        if kind == .table {
            context.fill(box, with: .color(Color(.systemGray5)))
            return
        }
        context.fill(box, with: .color(Color.accentColor.opacity(0.12)))
        if let symbol = kind.symbol {
            let side = min(frame.width, frame.height) * 0.6
            var image = context.resolve(Image(systemName: symbol))
            image.shading = .color(.accentColor)
            context.draw(image, in: CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side))
        }
    }

    private func drawSeat(_ seat: Seat, in context: inout GraphicsContext, scale: CGFloat) {
        guard let frame = rect(seat.image, scale: scale) else { return }
        let free = seat.available == true
        let seatRect = frame.insetBy(dx: frame.width * 0.08, dy: frame.height * 0.08)

        var local = context
        // Rotazione attorno al centro: 0° = schienale in alto (rivolto verso il basso).
        local.translateBy(x: seatRect.midX, y: seatRect.midY)
        local.rotate(by: .degrees(seat.image?.rotation ?? 0))
        let centered = CGRect(x: -seatRect.width / 2, y: -seatRect.height / 2,
                              width: seatRect.width, height: seatRect.height)
        let body = Path(roundedRect: centered, cornerRadius: centered.width * 0.2)
        let backrest = Path(roundedRect: CGRect(x: centered.minX, y: centered.minY,
                                                width: centered.width, height: centered.height * 0.22),
                            cornerRadius: centered.width * 0.15)

        // Libero = pieno verde; occupato = solo contorno: la forma distingue anche
        // senza colore.
        if free {
            local.fill(body, with: .color(.green))
            local.fill(backrest, with: .color(Color.black.opacity(0.18)))
        } else {
            local.fill(body, with: .color(Color(.systemGray6)))
            local.stroke(body, with: .color(Color(.systemGray2)), lineWidth: 1.2)
            local.stroke(backrest, with: .color(Color(.systemGray2)), lineWidth: 1)
            if differentiateWithoutColor {
                var cross = Path()
                cross.move(to: CGPoint(x: centered.minX + 4, y: centered.minY + 4))
                cross.addLine(to: CGPoint(x: centered.maxX - 4, y: centered.maxY - 4))
                cross.move(to: CGPoint(x: centered.maxX - 4, y: centered.minY + 4))
                cross.addLine(to: CGPoint(x: centered.minX + 4, y: centered.maxY - 4))
                local.stroke(cross, with: .color(Color(.systemGray)), lineWidth: 1)
            }
        }

        // Etichetta (senza rotazione, sempre leggibile); nascosta se troppo piccola.
        let fontSize = seatRect.height * 0.3
        if let label = seat.label, fontSize >= 9 {
            let text = Text(label)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(free ? Color.black : Color.secondary)
            context.draw(text, at: CGPoint(x: seatRect.midX, y: seatRect.midY + seatRect.height * 0.08))
        }
    }
}
