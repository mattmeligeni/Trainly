//
//  ScioperiView.swift
//  Trainly
//
//  Elenco scioperi ferroviari (feed MIT). Aggiornato al massimo una volta al giorno.
//

internal import SwiftUI

struct ScioperiView: View {

    @StateObject private var store = ScioperiStore()

    var body: some View {
        List {
            if let feed = store.feed {
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
                }

                if feed.strikes.isEmpty {
                    Section {
                        Text("Nessuno sciopero ferroviario in programma")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section("Scioperi ferroviari") {
                        ForEach(feed.strikes) { strikeRow($0) }
                    }
                }
            } else if let error = store.errorMessage {
                Section { Text(error).foregroundColor(.secondary) }
            }
        }
        .overlay {
            if store.isLoading && store.feed == nil { ProgressView() }
        }
        .navigationTitle("Scioperi")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refreshIfNeeded() }
    }

    private func strikeRow(_ s: StrikeInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.tint)
                Text(dateRange(s))
                    .font(.subheadline.weight(.semibold))
            }

            Text(relevance(s))
                .font(.caption)
                .foregroundColor(.secondary)

            // I due campi (modalità/sindacati) a volte sono invertiti nel feed:
            // li mostriamo differenziati, senza etichetta.
            if let a = s.fieldA, !a.isEmpty {
                Text(a).font(.footnote)
            }
            if let b = s.fieldB, !b.isEmpty {
                Text(b).font(.footnote).italic().foregroundColor(.secondary)
            }

            if let cat = s.categoria, !cat.isEmpty {
                Label(cat, systemImage: "person.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func dateRange(_ s: StrikeInfo) -> String {
        switch (s.dataInizio, s.dataFine) {
        case let (start?, end?) where start != end: return "\(start) → \(end)"
        case let (start?, _): return start
        case let (_, end?): return end
        default: return "—"
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
}

#Preview {
    NavigationStack { ScioperiView() }
}
