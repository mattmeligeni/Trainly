//
//  InfomobilitaView.swift
//  Trainly
//
//  Avvisi di infomobilità Trenitalia. Si aggiorna a ogni apertura.
//

internal import SwiftUI

struct InfomobilitaView: View {

    @EnvironmentObject private var router: AppRouter
    @Environment(\.openURL) private var openURL

    @State private var items: [InfoItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expandedIDs: Set<UUID> = []
    @State private var selectedTrain: TrainRequest?
    @State private var scrollTarget: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let errorMessage, !isLoading {
                    Section { Text(errorMessage).foregroundColor(.secondary) }
                } else if items.isEmpty && !isLoading {
                    Section { Text("Nessun avviso disponibile").foregroundColor(.secondary) }
                } else {
                    ForEach(items) { item in
                        Section {
                            DisclosureGroup(isExpanded: expandedBinding(item.id)) {
                                itemBody(item)
                            } label: {
                                itemHeader(item)
                            }
                        }
                        .id(item.id)
                    }
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
        .overlay {
            if isLoading && items.isEmpty { ProgressView() }
        }
        .navigationTitle("Infomobilità Trenitalia")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        // Ricarica (e apre il box del disservizio) a ogni apertura, anche quando
        // si torna al tab già navigato: onAppear scatta a ogni ricomparsa.
        .onAppear { Task { await load() } }
        // Treno aperto nella stessa tab: si torna indietro all'infomobilità.
        .navigationDestination(item: $selectedTrain) { request in
            TrainLoaderView(request: request)
        }
    }

    // MARK: - Header / body

    private func itemHeader(_ item: InfoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let style = colorStyle(item.color)
            Image(systemName: style.symbol)
                .font(.subheadline)
                .foregroundStyle(style.color)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                if !item.date.isEmpty {
                    Text(item.date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.tags) { tagBadge($0) }
                    }
                }
            }
        }
    }

    private func itemBody(_ item: InfoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.text.characters.isEmpty {
                Text(item.text)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineSpacing(2)
            }
            ForEach(item.links) { link in
                linkView(link)
            }
        }
        .padding(.top, 4)
    }

    private func tagBadge(_ tag: InfoTag) -> some View {
        Text(tag.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(tag.highlighted ? .black : .secondary)
            .background(tag.highlighted ? Color.yellow : Color(.systemGray5))
            .clipShape(Capsule())
    }

    /// Colore + simbolo della left-bar del sito.
    private func colorStyle(_ color: String?) -> (color: Color, symbol: String) {
        switch color {
        case "red": return (.red, "exclamationmark.triangle.fill")
        case "orange": return (.orange, "message.fill")
        case "green": return (.green, "clock.fill")
        default: return (.secondary, "info.circle.fill")
        }
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { if $0 { expandedIDs.insert(id) } else { expandedIDs.remove(id) } }
        )
    }

    // MARK: - Link

    @ViewBuilder
    private func linkView(_ link: InfoLink) -> some View {
        if let ref = link.trainRef {
            // Corsa esatta -> apre il treno nella stessa tab.
            Button {
                selectedTrain = .exactTrenitalia(ref)
            } label: {
                linkLabel(link, icon: "tram.fill")
            }
            .buttonStyle(.plain)
        } else if link.isGenericSearch {
            // Link "cerca treno" generico -> apre il tab Cerca dell'app.
            Button {
                router.openSearchTab()
            } label: {
                linkLabel(link, icon: "magnifyingglass")
            }
            .buttonStyle(.plain)
        } else if let url = link.url {
            Button {
                openURL(url)
            } label: {
                linkLabel(link, icon: iconName(for: url))
            }
            .buttonStyle(.plain)
        } else {
            linkLabel(link, icon: "link")
        }
    }

    private func linkLabel(_ link: InfoLink, icon: String) -> some View {
        HStack(spacing: 8) {
            Text("(\(link.number))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tint)
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(link.label)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func iconName(for url: URL) -> String {
        url.pathExtension.lowercased() == "pdf" ? "doc.text" : "arrow.up.right.square"
    }

    private func load() async {
        guard !isLoading else { return }   // evita caricamenti concorrenti
        isLoading = true
        errorMessage = nil
        do {
            items = try await InfomobilitaService.fetch()
            expandedIDs = []   // tutti i box chiusi di default
            highlightPendingTrain()
        } catch {
            items = []
            errorMessage = "Impossibile caricare l'infomobilità."
        }
        isLoading = false
    }

    /// Se si arriva da "Maggiori info sul disservizio", apre e scorre al box.
    private func highlightPendingTrain() {
        guard let number = router.pendingInfoTrain,
              let target = items.first(where: { item in
                  item.links.contains { $0.trainRef?.numero == number }
              }) else { return }
        expandedIDs.insert(target.id)
        router.pendingInfoTrain = nil
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            scrollTarget = target.id
        }
    }
}

#Preview {
    NavigationStack {
        InfomobilitaView()
            .environmentObject(AppRouter())
    }
}
