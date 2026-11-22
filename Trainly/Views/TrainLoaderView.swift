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
    /// Codice stazione di origine (preferiti Trenitalia): apre proprio quel treno.
    var originCode: String? = nil

    @State private var journey: TrainJourney?
    @State private var dateOptions: [ExactTrenitaliaRef] = []
    @State private var currentRef: ExactTrenitaliaRef?
    @State private var isLoading = true
    @State private var failure: TrainLoadFailure?

    var body: some View {
        Group {
            if let journey {
                TrainView(
                    journey: journey,
                    favorite: favorite(for: journey),
                    dateOptions: dateOptions,
                    currentRef: currentRef,
                    loadRef: { ref in
                        try await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                            numero: ref.numero, codOrigine: ref.codOrigine,
                            timestamp: ref.timestamp, descrizione: ""))
                    },
                    disserviceCheckNumber: disserviceCheckNumber,
                    reload: { try await reloadJourney() }
                )
            } else if let failure {
                // Il motivo vero (offline, non trovato, servizio giù) invece di un errore generico.
                ContentUnavailableView {
                    Label(failure.title, systemImage: failure.systemImage)
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("Riprova") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                }
            } else {
                ProgressView("Caricamento treno...")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Solo il primo caricamento: poi aggiorna la TrainView. Ricaricare a ogni
            // ritorno sulla tab cancellava il treno se la rete mancava.
            guard journey == nil else { return }
            await load()
        }
    }

    // MARK: - Caricamento

    private func load() async {
        isLoading = true
        failure = nil
        do {
            switch request {
            case .exactTrenitalia(let ref):
                let j = try await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                    numero: ref.numero, codOrigine: ref.codOrigine,
                    timestamp: ref.timestamp, descrizione: ""))
                dateOptions = await TrenitaliaService.dateOptions(
                    numero: ref.numero, origine: ref.codOrigine, including: ref)
                currentRef = ref
                journey = j

            case .vectorNumber(let vector, let number):
                if vector == "Trenitalia" {
                    let d = try await TrenitaliaService.detail(numeroTreno: number, origine: originCode)
                    currentRef = d.currentRef
                    dateOptions = d.dateOptions
                    journey = d.journey
                } else {
                    journey = try await TrainService.fetch(vector: vector, numero: number)
                }
            }
        } catch {
            // Annullato (vista chiusa): nessun errore da mostrare.
            failure = TrainLoadFailure(error)
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

    private func reloadJourney() async throws -> TrainJourney {
        switch request {
        case .exactTrenitalia(let ref):
            return try await TrenitaliaService.journey(from: TrenitaliaTrainRef(
                numero: ref.numero, codOrigine: ref.codOrigine,
                timestamp: ref.timestamp, descrizione: ""))
        case .vectorNumber(let vector, let number):
            if vector == "Trenitalia" {
                return try await TrenitaliaService.detail(numeroTreno: number, origine: originCode).journey
            }
            return try await TrainService.fetch(vector: vector, numero: number)
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
            category: journey.category,
            originCode: currentRef?.codOrigine ?? originCode
        )
    }
}
