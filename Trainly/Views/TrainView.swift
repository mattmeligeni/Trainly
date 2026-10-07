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

    @State private var journey: TrainJourney

    /// Descrittore per i preferiti; nil = pulsante stella nascosto (es. preview).
    private let favorite: FavoriteTrain?

    /// Ricarica i dati (pull-to-refresh). Restituisce nil se il reload fallisce.
    private let reload: () async -> TrainJourney?

    /// Stesse corse su più giorni (picker date); vuoto = nessun picker.
    private let dateOptions: [ExactTrenitaliaRef]
    private let loadRef: ((ExactTrenitaliaRef) async -> TrainJourney?)?
    /// Numero treno (Trenitalia) da verificare in infomobilità; nil = nessun controllo
    /// (es. aperto DA infomobilità: l'utente è già al corrente).
    private let disserviceCheckNumber: String?
    @State private var selectedRef: ExactTrenitaliaRef?
    @State private var showReport = false
    @State private var disserviceNumber: String?

    init(journey: TrainJourney,
         favorite: FavoriteTrain? = nil,
         dateOptions: [ExactTrenitaliaRef] = [],
         currentRef: ExactTrenitaliaRef? = nil,
         loadRef: ((ExactTrenitaliaRef) async -> TrainJourney?)? = nil,
         disserviceCheckNumber: String? = nil,
         reload: @escaping () async -> TrainJourney? = { nil }) {
        _journey = State(initialValue: journey)
        self.favorite = favorite
        self.dateOptions = dateOptions
        self.loadRef = loadRef
        self.disserviceCheckNumber = disserviceCheckNumber
        _selectedRef = State(initialValue: currentRef ?? dateOptions.first)
        self.reload = reload
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if dateOptions.count > 1 { datePicker }
                timeline
            }
            .padding(.horizontal)
            .padding(.vertical, 20)
        }
        // Applicato allo ScrollView (innermost): così la .sheet esterna NON eredita
        // il pull-to-refresh (\.refresh non è azzerabile perché è get-only).
        .refreshable {
            if let ref = selectedRef, let loadRef, let updated = await loadRef(ref) {
                journey = updated
            } else if let updated = await reload() {
                journey = updated
            }
        }
        .background(Color(.systemGroupedBackground))
        // Solo categoria + numero (es. "Frecciarossa 8519"); il vettore è nel badge.
        .navigationTitle(trainLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showReport = true
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .accessibilityLabel("Segnalazioni")
            }
            if let favorite {
                ToolbarItem(placement: .topBarTrailing) {
                    let isSaved = favorites.contains(favorite.id)
                    Button {
                        favorites.toggle(favorite)
                    } label: {
                        Image(systemName: isSaved ? "star.fill" : "star")
                            .foregroundStyle(isSaved ? .yellow : .accentColor)
                    }
                    .accessibilityLabel(isSaved ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
                }
            }
        }
        .sheet(isPresented: $showReport) {
            TrainReportView(number: journey.trainNumber,
                            route: "\(journey.origin) → \(journey.destination)")
        }
        .task { await checkDisservice() }
        .onChange(of: selectedRef) { _, ref in
            guard let ref, let loadRef else { return }
            Task { if let updated = await loadRef(ref) { journey = updated } }
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

    /// Verifica se il treno (senza notice proprio) è colpito da un avviso in
    /// infomobilità; in tal caso mostra "Maggiori info sul disservizio".
    private func checkDisservice() async {
        guard let number = disserviceCheckNumber, journey.notice == nil else { return }
        if await InfomobilitaService.containsTrain(number) {
            disserviceNumber = number
        }
    }

    private static func dateLabel(_ millis: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return f.string(from: date)
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
            HStack(spacing: 14) {
                // Predisposizione immagine treno
                trainImage

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
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
            }

            if let notice = journey.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(spacing: 12) {
                positionSection
                Divider().frame(height: 40)
                delaySection
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    }

    // Trenitalia fornisce l'ultimo rilevamento; gli altri la prossima fermata.
    private var positionSection: some View {
        let title: String
        let station: String
        let time: Date?

        if journey.hasLivePosition {
            title = "Ultimo rilevamento"
            station = journey.lastDetectionStation ?? "--"
            time = journey.lastDetectionTime
        } else if let next = journey.nextStop {
            title = "Prossima fermata"
            station = next.stationName
            time = next.actualArrival ?? next.scheduledArrival
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let time {
                Text(Self.hm(time))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var delaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Stato", systemImage: journey.delayMinutes > 0 ? "clock" : "checkmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(delayText)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(journey.delayMinutes > 0 ? .red : .green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Mostra il ritardo come da JSON: negativo = anticipo (verde),
    // positivo = ritardo (rosso), zero = in orario.
    private var delayText: String {
        let d = journey.delayMinutes
        if d == 0 { return "In orario" }
        let n = abs(d)
        let unit = n == 1 ? "minuto" : "minuti"
        return d < 0 ? "Anticipo di \(n) \(unit)" : "In ritardo di \(n) \(unit)"
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func hm(_ date: Date) -> String {
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
                            .font(.body.weight(stop.isPassed ? .regular : .semibold))
                            .foregroundColor(stop.isPassed ? .secondary : .primary)
                        if let orientation = stop.orientation {
                            Label(orientation, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if stop.isExtraordinary {
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
                    if let platform = stop.platform {
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
                            estimated: stop.estimatedArrival
                        )
                    }
                    if stop.scheduledDeparture != nil || stop.actualDeparture != nil {
                        TimeColumn(
                            title: "Partenza",
                            scheduled: stop.scheduledDeparture,
                            actual: stop.actualDeparture,
                            estimated: stop.estimatedDeparture
                        )
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Binario (chiaro = previsto, scuro = confermato)

private struct PlatformBadge: View {
    let platform: String
    let confirmed: Bool

    var body: some View {
        HStack(spacing: 4) {
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
    }
}

// MARK: - Colonna orario (previsto barrato + effettivo)

private struct TimeColumn: View {
    let title: String
    let scheduled: Date?
    let actual: Date?
    var estimated: Date? = nil

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.formatter.string(from: date)
    }

    // Orario "vivo": effettivo se disponibile, altrimenti previsto (stima).
    private var live: Date? { actual ?? estimated }

    private var isDelayed: Bool {
        guard let s = scheduled, let l = live else { return false }
        return TrainJourney.difference(l, from: s) >= 60   // da 1 minuto in poi = in ritardo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                if let live = string(live) {
                    // Effettivo o previsto: verde se in orario/anticipo, arancione se in ritardo.
                    Text(live)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(isDelayed ? .orange : .green)
                    // Programmato barrato solo se diverso.
                    if let sched = string(scheduled), sched != live {
                        Text(sched)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .strikethrough()
                    }
                } else if let sched = string(scheduled) {
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
