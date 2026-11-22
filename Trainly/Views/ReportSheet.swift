//
//  ReportSheet.swift
//  Trainly
//
//  Modali di segnalazione. Senza un backend, il testo compilato si invia con il
//  menu di condivisione (Mail, Messaggi…), così non va perso.
//

internal import SwiftUI

/// Segnalazione su uno specifico treno (dal dettaglio treno).
struct TrainReportView: View {
    let number: String
    let route: String

    @Environment(\.dismiss) private var dismiss
    @State private var type = "Fermate"
    @State private var message = ""

    private let types = ["Fermate", "Orari", "Altro"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Treno") {
                    LabeledContent("Numero", value: number)
                    LabeledContent("Tratta", value: route)
                }
                Section("Tipo di problema") {
                    Picker("Tipo", selection: $type) {
                        ForEach(types, id: \.self) { Text($0) }
                    }
                }
                Section("Descrizione") {
                    TextField("Descrivi il problema…", text: $message, axis: .vertical)
                        .lineLimit(4...8)
                }
                Section {
                    ShareLink(item: reportText, subject: Text("Segnalazione treno \(number)")) {
                        Label("Invia segnalazione", systemImage: "paperplane")
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Si apre il menu di condivisione: scegli Mail o un'altra app.")
                }
            }
            .navigationTitle("Segnalazione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .modalKeyboardSafe()
    }

    private var reportText: String {
        "Segnalazione Trainly\nTreno: \(number)\nTratta: \(route)\nProblema: \(type)\n\n\(message)"
    }
}

/// Segnalazione generica (dalle Impostazioni): problema su un treno o sulla ricerca.
struct GeneralReportView: View {

    enum Kind: String, CaseIterable, Identifiable {
        case treno = "Treno"
        case ricerca = "Ricerca"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .treno
    @State private var number = ""
    @State private var route = ""
    @State private var vector = "Trenitalia"
    @State private var message = ""

    private let vectors = ["Trenitalia", "Italo", "Trenord"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tipo", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch kind {
                case .treno:
                    Section("Treno") {
                        TextField("Numero treno", text: $number)
                            .keyboardType(.numberPad)
                        TextField("Tratta (origine → destinazione)", text: $route)
                    }
                case .ricerca:
                    Section("Ricerca") {
                        Picker("Vettore", selection: $vector) {
                            ForEach(vectors, id: \.self) { Text($0) }
                        }
                    }
                }

                Section("Descrizione") {
                    TextField("Descrivi il problema…", text: $message, axis: .vertical)
                        .lineLimit(4...8)
                }
                Section {
                    ShareLink(item: reportText, subject: Text("Segnalazione Trainly")) {
                        Label("Invia segnalazione", systemImage: "paperplane")
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Si apre il menu di condivisione: scegli Mail o un'altra app.")
                }
            }
            .navigationTitle("Segnalazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .modalKeyboardSafe()
    }

    private var reportText: String {
        switch kind {
        case .treno:
            return "Segnalazione Trainly (treno)\nTreno: \(number)\nTratta: \(route)\n\n\(message)"
        case .ricerca:
            return "Segnalazione Trainly (ricerca)\nVettore: \(vector)\n\n\(message)"
        }
    }
}

#Preview {
    TrainReportView(number: "8509", route: "Sibari → Bolzano")
}
