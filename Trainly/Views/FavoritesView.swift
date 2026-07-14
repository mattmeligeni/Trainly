//
//  FavoritesView.swift
//  Trainly
//
//  Created by Mattia Meligeni on 12/07/2026.
//

internal import SwiftUI

struct FavoritesView: View {

    @EnvironmentObject private var favorites: FavoritesStore

    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @FocusState private var searchFocused: Bool

    private let vectorOrder = ["Trenitalia", "Italo", "Trenord"]

    var body: some View {
        Group {
            if favorites.favorites.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    searchField
                    list
                }
            }
        }
        .navigationDestination(for: FavoriteTrain.self) { favorite in
            TrainLoaderView(request: .vectorNumber(vector: favorite.vector, number: favorite.number))
        }
    }

    // MARK: - Ricerca (nome, tratta o vettore)

    private var filtered: [FavoriteTrain] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return favorites.favorites }
        return favorites.favorites.filter {
            $0.title.lowercased().contains(q)
            || $0.subtitle.lowercased().contains(q)
            || $0.vector.lowercased().contains(q)
            || $0.number.lowercased().contains(q)
        }
    }

    private var orderedVectors: [String] {
        let present = Set(filtered.map(\.vector))
        let known = vectorOrder.filter(present.contains)
        let others = present.subtracting(vectorOrder).sorted()
        return known + others
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Cerca per nome, tratta o vettore…", text: $query)
                .autocorrectionDisabled(true)
                .textContentType(.jobTitle)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            Spacer()
            Text("Nessun risultato")
                .foregroundColor(.secondary)
            Spacer()
        } else {
            List {
                ForEach(orderedVectors, id: \.self) { vector in
                    let favs = filtered.filter { $0.vector == vector }
                    Section {
                        DisclosureGroup(isExpanded: expandedBinding(vector)) {
                            ForEach(favs) { favorite in
                                NavigationLink(value: favorite) { row(favorite) }
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            favorites.remove(favorite.id)
                                        } label: {
                                            Label("Elimina", systemImage: "trash")
                                        }
                                    }
                            }
                        } label: {
                            Text("\(vector) (\(favs.count))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func expandedBinding(_ vector: String) -> Binding<Bool> {
        Binding(
            // Durante la ricerca teniamo tutto aperto.
            get: { !query.trimmingCharacters(in: .whitespaces).isEmpty || !collapsed.contains(vector) },
            set: { expanded in
                if expanded { collapsed.remove(vector) } else { collapsed.insert(vector) }
            }
        )
    }

    private func row(_ favorite: FavoriteTrain) -> some View {
        HStack(spacing: 14) {
            Group {
                if let category = favorite.category, UIImage(named: category) != nil {
                    Image(category)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.logoTile)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(favorite.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Nessun preferito")
                .font(.title3.weight(.semibold))
            Text("Aggiungi un treno ai preferiti dalla schermata del treno per ritrovarlo qui velocemente.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

#Preview {
    NavigationStack {
        FavoritesView()
            .navigationTitle("Preferiti")
    }
    .environmentObject(FavoritesStore())
}
