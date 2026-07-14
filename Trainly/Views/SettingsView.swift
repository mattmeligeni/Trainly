//
//  SettingsView.swift
//  Trainly
//
//  Created by Mattia Meligeni on 12/07/2026.
//

internal import SwiftUI

struct SettingsView: View {

    @AppStorage("defaultVector") private var defaultVector: String = "Trenitalia"
    @AppStorage("appearance") private var appearance: String = "system"

    @State private var showNotificationsAlert = false
    @State private var showReport = false

    private let vectors = ["Trenitalia", "Italo", "Trenord"]

    var body: some View {
        Form {
            // MARK: - Generali
            Section("Generali") {
                Picker("Vettore predefinito", selection: $defaultVector) {
                    ForEach(vectors, id: \.self) { Text($0) }
                }
            }

            // MARK: - Aspetto
            Section("Aspetto") {
                Picker("Tema", selection: $appearance) {
                    Text("Sistema").tag("system")
                    Text("Chiaro").tag("light")
                    Text("Scuro").tag("dark")
                }
            }

            // MARK: - Notifiche
            Section {
                Button {
                    showNotificationsAlert = true
                } label: {
                    HStack {
                        Label("Avvisi di ritardo", systemImage: "bell.badge")
                        Spacer()
                        Text("Presto")
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.primary)
            } header: {
                Text("Notifiche")
            }

            // MARK: - Segnalazioni
            Section("Segnalazioni") {
                Button {
                    showReport = true
                } label: {
                    Label("Segnala un problema", systemImage: "exclamationmark.bubble")
                }
                .tint(.primary)
            }

            // MARK: - Informazioni
            Section("Informazioni") {
                LabeledContent("Versione", value: appVersion)
                LabeledContent("Sviluppatore", value: "Mattia Meligeni")
            }

            // MARK: - Disclaimer
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Disclaimer")
                        .font(.footnote.weight(.semibold))
                    Text("Quest'app non si assume alcuna responsabilità sull'esattezza dei dati mostrati. Controlla sempre gli orari in stazione o presso il vettore. Trainly non è affiliata a Trenitalia, Italo o Trenord.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("© 2026 Mattia Meligeni. Tutti i diritti riservati.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
        }
        .alert("Notifiche", isPresented: $showNotificationsAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Gli avvisi di ritardo saranno attivati in un prossimo aggiornamento.")
        }
        .sheet(isPresented: $showReport) {
            GeneralReportView()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .navigationTitle("Impostazioni")
    }
}
