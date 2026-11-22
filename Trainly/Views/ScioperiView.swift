//
//  ScioperiView.swift
//  Trainly
//
//  Elenco scioperi ferroviari (feed MIT). Aggiornato al massimo ogni 2 ore.
//

internal import SwiftUI

struct ScioperiView: View {

    @StateObject private var store = ScioperiStore()

    var body: some View {
        List {
            if let feed = store.feed {
                let sections = feed.sections()

                // Metadati del feed in alto.
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feed.title)
                            .font(.headline)
                        Text(feed.description)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    statusRow(feed)
                }

                if sections.isEmpty {
                    Section {
                        ContentUnavailableView("Nessuno sciopero ferroviario in programma",
                                               systemImage: "checkmark.circle")
                    }
                } else {
                    ForEach(sections, id: \.section) { group in
                        Section(group.section.title) {
                            ForEach(group.strikes) { strikeRow($0) }
                        }
                    }
                }
            }
        }
        .overlay {
            if store.feed == nil {
                if store.isLoading {
                    ProgressView()
                } else if let error = store.errorMessage {
                    ContentUnavailableView {
                        Label("Scioperi non disponibili", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Riprova") { Task { await store.refresh() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("Scioperi")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refreshIfNeeded() }
    }

    /// "Aggiornato alle HH:mm", oppure l'errore dell'ultimo refresh con Riprova
    /// (i dati in cache restano visibili).
    @ViewBuilder
    private func statusRow(_ feed: ScioperiFeed) -> some View {
        if let error = store.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("\(error) Dati \(Self.updatedString(feed.updatedAt)).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline)
                Button("Riprova") { Task { await store.refresh() } }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoading)
            }
            .padding(.vertical, 2)
        } else {
            Label("Aggiornato \(Self.updatedString(feed.updatedAt))", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func strikeRow(_ s: StrikeInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(dateRange(s))
                    .font(.subheadline.weight(.semibold))
            }

            Text(relevance(s))
                .font(.caption)
                .foregroundColor(.secondary)

            // I due campi (modalità/sindacati) a volte sono invertiti nel feed:
            // `modality`/`unions` li riordinano, qui li mostriamo con l'etichetta.
            if let m = s.modality {
                labeledField("Modalità", m)
            }
            if let u = s.unions {
                labeledField("Sindacati", u)
            }

            if let cat = s.categoria, !cat.isEmpty {
                Label(cat, systemImage: "person.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        // VoiceOver: una riga = uno sciopero, letto per intero.
        .accessibilityElement(children: .combine)
    }

    private func labeledField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
        }
    }

    /// Date con giorno della settimana ("sab 22 nov → dom 23 nov").
    private func dateRange(_ s: StrikeInfo) -> String {
        switch (s.startDay, s.endDay) {
        case let (start?, end?) where start != end:
            return "\(Self.dayString(start)) → \(Self.dayString(end))"
        case let (start?, _):
            return Self.dayString(start)
        default:
            // Data non interpretabile: si mostra il testo del feed.
            return s.dataInizio ?? s.dataFine ?? "—"
        }
    }

    private func relevance(_ s: StrikeInfo) -> String {
        var comps: [String] = []
        if let set = s.settore, !set.isEmpty { comps.append(set) }
        if let ril = s.rilevanza, !ril.isEmpty { comps.append(ril) }
        // Nazionale: solo la rilevanza. Locale/Regionale: aggiungi regione/provincia.
        if let ril = s.rilevanza?.lowercased(), ril != "nazionale" {
            if let r = s.regione, !r.isEmpty, r.lowercased() != "italia" { comps.append(r) }
            if let p = s.provincia, !p.isEmpty, p.lowercased() != "tutte" { comps.append("(\(p))") }
        }
        return comps.joined(separator: " · ")
    }

    // MARK: - Formatter (it_IT, Europe/Rome)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        f.dateFormat = format
        return f
    }

    private static let dayFormatter = formatter("EEE d MMM")
    private static let dayYearFormatter = formatter("EEE d MMM yyyy")
    private static let timeFormatter = formatter("HH:mm")
    private static let shortDayFormatter = formatter("d MMM")

    private static func dayString(_ date: Date) -> String {
        let cal = StrikeInfo.romeCalendar
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return (sameYear ? dayFormatter : dayYearFormatter).string(from: date)
    }

    /// "alle 14:32" se oggi, altrimenti "il 21 nov alle 14:32" (cache vecchia, offline).
    private static func updatedString(_ date: Date) -> String {
        let time = timeFormatter.string(from: date)
        if StrikeInfo.romeCalendar.isDateInToday(date) { return "alle \(time)" }
        return "il \(shortDayFormatter.string(from: date)) alle \(time)"
    }
}

#Preview {
    NavigationStack { ScioperiView() }
}
