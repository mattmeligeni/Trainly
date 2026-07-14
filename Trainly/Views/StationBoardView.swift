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

    @State private var arrivals = false   // false = Partenze, true = Arrivi
    @State private var trains: [RFITrain] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedTrain: TrainRequest?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $arrivals) {
                Text("Partenze").tag(false)
                Text("Arrivi").tag(true)
            }
            .pickerStyle(.segmented)
            .padding()

            content
        }
        .navigationTitle(station.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Al cambio segmento svuota subito e ricarica; il pull-to-refresh no.
        .task(id: arrivals) { await load(clearFirst: true) }
        .refreshable { await load() }
        // Apre il treno nella stessa tab: tornando indietro si resta sul tabellone.
        .navigationDestination(item: $selectedTrain) { request in
            TrainLoaderView(request: request)
        }
    }

    // Sempre una List, così il pull-to-refresh funziona anche su errore/vuoto.
    private var content: some View {
        List {
            if let errorMessage, !isLoading {
                messageRow(icon: "exclamationmark.triangle", text: errorMessage)
            } else if trains.isEmpty && !isLoading {
                messageRow(icon: "tram",
                           text: arrivals ? "Nessun arrivo previsto" : "Nessuna partenza prevista")
            } else {
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

    private func load(clearFirst: Bool = false) async {
        if clearFirst { trains = [] }   // svuota per mostrare lo spinner
        isLoading = true
        errorMessage = nil
        do {
            let result = try await RFIService.getTrains(placeId: station.code, arrivals: arrivals)
            // Se nel frattempo si è cambiato segmento, questo task è stato
            // cancellato: non tocchiamo lo stato del nuovo caricamento.
            if Task.isCancelled { return }
            trains = result
        } catch {
            if Task.isCancelled { return }   // errore dovuto alla cancellazione: ignora
            trains = []
            errorMessage = "Impossibile caricare il tabellone."
        }
        isLoading = false
    }

    private func messageRow(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowSeparator(.hidden)
    }

    // MARK: - Riga treno

    private func row(_ t: RFITrain) -> some View {
        Button {
            selectedTrain = .vectorNumber(vector: t.searchVector, number: t.treno)
        } label: {
            HStack(spacing: 12) {
                logo(t)

                VStack(alignment: .leading, spacing: 3) {
                    Text(t.badgeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(t.destinazione.capitalized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    numberBadge(t.treno)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(t.orario)
                        .font(.headline.monospacedDigit())
                    trailingInfo(t)
                }

                if t.inPartenza {
                    RailroadBlinker()
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .frame(width: 46, height: 46)
        .background(Color.logoTile)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func trailingInfo(_ t: RFITrain) -> some View {
        HStack(spacing: 6) {
            if let delay = t.delayMinutes {
                if delay > 0 {
                    Text("+\(delay)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                } else {
                    Text("in orario")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else if !t.ritardo.isEmpty {
                Text(t.ritardo.capitalized)
                    .font(.caption)
                    .foregroundColor(.orange)
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

// MARK: - Luce lampeggiante (passaggio a livello)

/// Due luci rosse che si alternano in modo netto, come un passaggio a livello.
struct RailroadBlinker: View {
    private let period = 0.45

    var body: some View {
        // Partenza da una data fissa (non `.now`): tutti i lampeggianti restano
        // sincronizzati anche se compaiono in momenti diversi.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: period)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / period) % 2 == 0
            HStack(spacing: 4) {
                dot(on: on)
                dot(on: !on)
            }
            .accessibilityLabel("In arrivo")
        }
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
