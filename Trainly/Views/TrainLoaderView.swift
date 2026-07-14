//
//  TrainLoaderView.swift
//  Trainly
//
//  Carica i dati di un treno e mostra la TrainView, restando nella tab corrente
//  (usato da Preferiti, Tabellone e Infomobilità: si torna indietro alla stessa pagina).
//

internal import SwiftUI

struct TrainLoaderView: View {

    let request: TrainRequest

    @State private var journey: TrainJourney?
    @State private var dateOptions: [ExactTrenitaliaRef] = []
    @State private var currentRef: ExactTrenitaliaRef?
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        Group {
            if let journey {
                TrainView(
                    journey: journey,
                    favorite: favorite(for: journey),
                    dateOptions: dateOptions,
                    currentRef: currentRef,
                    loadRef: { ref in
                        try? await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                            numero: ref.numero, codOrigine: ref.codOrigine,
                            timestamp: ref.timestamp, descrizione: ""))
                    },
                    disserviceCheckNumber: disserviceCheckNumber,
                    reload: { await reloadJourney() }
                )
            } else if isLoading {
                ProgressView("Caricamento treno...")
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Impossibile caricare il treno")
                        .font(.headline)
                    Button("Riprova") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Caricamento

    private func load() async {
        isLoading = true
        failed = false
        do {
            switch request {
            case .exactTrenitalia(let ref):
                let j = try await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                    numero: ref.numero, codOrigine: ref.codOrigine,
                    timestamp: ref.timestamp, descrizione: ""))
                journey = j
                currentRef = ref
                dateOptions = await TrenitaliaService.dateOptions(
                    numero: ref.numero, origine: ref.codOrigine, including: ref)

            case .vectorNumber(let vector, let number):
                if vector == "Trenitalia" {
                    let d = try await TrenitaliaService.detail(numeroTreno: number)
                    journey = d.journey
                    currentRef = d.currentRef
                    dateOptions = d.dateOptions
                } else {
                    journey = try await TrainService.fetch(vector: vector, numero: number)
                }
            }
        } catch {
            journey = nil
            failed = true
        }
        isLoading = false
    }

    /// Numero da verificare in infomobilità: solo per treni Trenitalia aperti per
    /// numero (ricerca/tabellone/preferiti), non dai link infomobilità.
    private var disserviceCheckNumber: String? {
        if case .vectorNumber(let vector, let number) = request, vector == "Trenitalia" {
            return number
        }
        return nil
    }

    private func reloadJourney() async -> TrainJourney? {
        switch request {
        case .exactTrenitalia(let ref):
            return try? await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                numero: ref.numero, codOrigine: ref.codOrigine,
                timestamp: ref.timestamp, descrizione: ""))
        case .vectorNumber(let vector, let number):
            return await TrainService.reload(vector: vector, numero: number)
        }
    }

    private var requestVector: String {
        switch request {
        case .exactTrenitalia: return "Trenitalia"
        case .vectorNumber(let vector, _): return vector
        }
    }

    private func favorite(for journey: TrainJourney) -> FavoriteTrain {
        FavoriteTrain(
            vector: requestVector,
            number: journey.trainNumber,
            title: journey.title,
            subtitle: "\(journey.origin) → \(journey.destination)",
            category: journey.category
        )
    }
}
