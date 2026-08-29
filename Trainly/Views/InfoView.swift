//
//  InfoView.swift
//  Trainly
//
//  Hub informazioni: Infomobilità e Scioperi.
//

internal import SwiftUI

struct InfoView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {

                // MARK: - Intestazione
                VStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.tint)
                    Text("Informazioni e utilità")
                        .font(.title3.weight(.semibold))
                    Text("Avvisi di circolazione, scioperi ferroviari e soluzioni di viaggio, tutto in un unico posto.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.top, 32)

                // MARK: - Card
                VStack(spacing: 14) {
                    NavigationLink(value: UtilityDestination.biglietti) {
                        card(icon: "ticket.fill",
                             tint: .green,
                             title: "Cerca Biglietti",
                             subtitle: "Orari e prezzi Trenitalia e Italo")
                    }
                    NavigationLink(value: UtilityDestination.bigliettiTrenord) {
                        card(icon: "tram.fill",
                             tint: .teal,
                             title: "Biglietti Trenord",
                             subtitle: "Orari e prezzi dei treni regionali Trenord")
                    }
                    NavigationLink(value: UtilityDestination.infomobilita) {
                        card(icon: "exclamationmark.bubble.fill",
                             tint: .orange,
                             title: "Infomobilità Trenitalia",
                             subtitle: "Avvisi, lavori e modifiche al servizio")
                    }
                    NavigationLink(value: UtilityDestination.scioperi) {
                        card(icon: "figure.walk.motion",
                             tint: .red,
                             title: "Scioperi",
                             subtitle: "Scioperi ferroviari in programma")
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func card(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        InfoView()
            .navigationTitle("Info")
            .environmentObject(AppRouter())
    }
}
