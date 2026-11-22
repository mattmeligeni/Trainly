//
//  StationsStore.swift
//  Trainly
//
//  Elenco stazioni RFI (da StazioniRFI.swift) + ricerca, recenti e principali.
//

import Foundation
internal import Combine

// MARK: - Modello stazione

struct RFIStation: Identifiable, Hashable, Codable {
    let name: String    // nome RFI in ALL CAPS, es. "MILANO CENTRALE"
    let code: String    // placeId per il monitor RFI, es. "1728"

    var id: String { code }

    /// Nome leggibile (Title Case) per la UI.
    /// Non `.capitalized`: darebbe "Forli'", "C.Le/Av", "Reggio Di Calabria".
    var displayName: String { StationName.display(name) }
}

// MARK: - Normalizzazione nomi

/// Nomi stazione RFI: forma leggibile per la UI e chiavi di ricerca.
nonisolated enum StationName {

    /// Preposizioni e articoli in minuscolo (tranne a inizio nome).
    private static let particles: Set<String> = [
        "A", "AD", "AI", "AL", "ALL", "ALLA", "ALLE", "ALLO", "D", "DA", "DAL", "DALL",
        "DE", "DEI", "DEGLI", "DEL", "DELL", "DELLA", "DELLE", "DELLO", "DI", "E", "ED",
        "IN", "NEL", "NELL", "NELLA", "PER", "SU", "SUI", "SUL", "SULL", "SULLA", "SULLO",
    ]

    /// Sigle da lasciare in maiuscolo.
    private static let acronyms: Set<String> = ["AV", "FS", "HB", "MP", "RFI", "SMN", "SNCF", "TAV", "II", "III", "IV"]

    /// Varianti di "San/Santa/Santo" che nel catalogo RFI compaiono come "S.".
    private static let saintAliases: Set<String> = ["SAN", "SANT", "SANTA", "SANTO"]

    private static let accented: [Character: Character] = [
        "A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù",
    ]

    // MARK: Nome leggibile

    /// "BOLOGNA C.LE/AV" -> "Bologna Centrale/AV", "FORLI'" -> "Forlì",
    /// "REGGIO DI CALABRIA" -> "Reggio di Calabria", "VENEZIA S.LUCIA" -> "Venezia S. Lucia".
    static func display(_ raw: String) -> String {
        var s = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "C.LE", with: "CENTRALE")
        s = accentTrailingApostrophes(s)
        s = spaceAfterSaintAbbreviation(s)

        // Divide in parole (lettere/cifre) e separatori, poi sistema le maiuscole.
        var tokens: [(text: String, isWord: Bool)] = []
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber
            if let last = tokens.last, last.isWord == isWord {
                tokens[tokens.count - 1].text.append(ch)
            } else {
                tokens.append((String(ch), isWord))
            }
        }

        var out = ""
        var seenWord = false
        for (index, token) in tokens.enumerated() {
            guard token.isWord else { out += token.text; continue }
            let next = index + 1 < tokens.count ? tokens[index + 1].text : ""
            let word = token.text
            if acronyms.contains(word) {
                out += word
            } else if seenWord && particles.contains(word)
                        && (next.hasPrefix(" ") || next.hasPrefix("'") || next.hasPrefix("’")) {
                // "E." in "REGGIO E." è un'abbreviazione, non la congiunzione.
                out += word.lowercased()
            } else {
                out += word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            seenWord = true
        }
        return out
    }

    /// "FORLI'" -> "FORLÌ": nel catalogo l'accento finale è scritto come apostrofo.
    /// L'apostrofo seguito da una lettera ("DELL'EMILIA") è un'elisione e resta.
    private static func accentTrailingApostrophes(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            if ch == "'", let prev = out.last, let acc = accented[prev] {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == nil || !(next!.isLetter) {
                    out[out.count - 1] = acc
                    continue
                }
            }
            out.append(ch)
        }
        return String(out)
    }

    /// "S.LUCIA" -> "S. LUCIA". Non si espande in San/Santa per non sbagliare il genere.
    private static func spaceAfterSaintAbbreviation(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, ch) in chars.enumerated() {
            out.append(ch)
            guard ch == ".", i >= 1, chars[i - 1] == "S",
                  i == 1 || !chars[i - 2].isLetter,
                  i + 1 < chars.count, chars[i + 1].isLetter else { continue }
            out.append(" ")
        }
        return out
    }

    /// Frase in maiuscolo RFI -> "Carrozza 1 in coda al treno" (solo la prima lettera maiuscola).
    static func sentence(_ raw: String) -> String {
        let s = accentTrailingApostrophes(raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines))
        return s.prefix(1).uppercased() + s.dropFirst().lowercased()
    }

    // MARK: Chiavi di ricerca

    /// Token normalizzati: maiuscolo, senza accenti, punteggiatura come spazio,
    /// "C.LE" -> "CENTRALE", "SAN/SANTA/SANTO/SANT'" -> "S".
    static func searchTokens(_ raw: String) -> [String] {
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                            locale: Locale(identifier: "it_IT")).uppercased()
        s = s.replacingOccurrences(of: "C.LE", with: " CENTRALE ")
        let cleaned = String(s.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").flatMap { token -> [String] in
            let t = String(token)
            // Sigla d'uso comune: "firenze smn" deve trovare Santa Maria Novella.
            if t == "SMN" { return ["S", "MARIA", "NOVELLA"] }
            return [saintAliases.contains(t) ? "S" : t]
        }
    }

    /// Ogni token della query deve essere prefisso di almeno un token della stazione.
    static func matches(query: [String], key: [String]) -> Bool {
        query.allSatisfy { q in
            key.contains { k in
                // "SA", "SANT"… digitati a metà devono trovare anche le "S.".
                k.hasPrefix(q) || (k == "S" && ("SANTA".hasPrefix(q) || "SANTO".hasPrefix(q)))
            }
        }
    }
}

// MARK: - Store

@MainActor
final class StationsStore: ObservableObject {

    /// Ultime stazioni scelte (persistite).
    @Published private(set) var recents: [RFIStation] = []

    /// Stazioni preferite (persistite), nell'ordine in cui sono state aggiunte.
    @Published private(set) var favorites: [RFIStation] = []

    /// Tutte le stazioni, ordinate per nome.
    let all: [RFIStation]

    /// Stazioni principali per accesso rapido.
    let principali: [RFIStation] = [
        RFIStation(name: "MILANO CENTRALE", code: "1728"),
        RFIStation(name: "BOLOGNA C.LE/AV", code: "942"),
        RFIStation(name: "ROMA TERMINI", code: "2416"),
        RFIStation(name: "FIRENZE SANTA MARIA NOVELLA", code: "1325"),
        RFIStation(name: "BARI CENTRALE", code: "595"),
    ]

    private let recentsKey = "recentStations"
    private let favoritesKey = "favoriteStations"
    private let maxRecents = 5

    /// Indice di ricerca calcolato una sola volta per tutta l'app
    /// (le chiavi normalizzate non si ricalcolano a ogni lettera digitata).
    private struct IndexEntry {
        let station: RFIStation
        let tokens: [String]
        let joined: String
    }

    private static let index: [IndexEntry] = stationIDs
        .map { RFIStation(name: $0.key, code: $0.value) }
        .sorted { $0.name < $1.name }
        .map { station in
            let tokens = StationName.searchTokens(station.name)
            return IndexEntry(station: station, tokens: tokens, joined: tokens.joined(separator: " "))
        }

    init() {
        all = Self.index.map(\.station)
        loadRecents()
        favorites = load(favoritesKey)
    }

    /// Filtra le stazioni con chiavi normalizzate: "Forlì", "forli'",
    /// "bologna centrale", "milano garibaldi", "santa lucia" trovano la stazione.
    func search(_ query: String) -> [RFIStation] {
        let q = StationName.searchTokens(query)
        guard !q.isEmpty else { return [] }
        let qJoined = q.joined(separator: " ")
        // Prima i match che iniziano con la query, poi quelli con la prima
        // parola giusta, poi gli altri (a parità, ordine alfabetico).
        func rank(_ e: IndexEntry) -> Int {
            if e.joined.hasPrefix(qJoined) { return 0 }
            if let first = e.tokens.first, first.hasPrefix(q[0]) { return 1 }
            return 2
        }
        return Self.index
            .filter { StationName.matches(query: q, key: $0.tokens) }
            .map { (entry: $0, rank: rank($0)) }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.entry.station.name < $1.entry.station.name
            }
            .map(\.entry.station)
    }

    /// Registra una stazione tra le recenti (in cima, senza duplicati).
    func addRecent(_ station: RFIStation) {
        recents.removeAll { $0.code == station.code }
        recents.insert(station, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        saveRecents()
    }

    /// Toglie una stazione dalle recenti (swipe nella lista).
    func removeRecent(_ station: RFIStation) {
        recents.removeAll { $0.code == station.code }
        saveRecents()
    }

    // MARK: - Preferite

    func isFavorite(_ station: RFIStation) -> Bool {
        favorites.contains { $0.code == station.code }
    }

    func toggleFavorite(_ station: RFIStation) {
        if isFavorite(station) {
            favorites.removeAll { $0.code == station.code }
        } else {
            favorites.append(station)
        }
        save(favorites, favoritesKey)
    }

    // MARK: - Persistenza

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([RFIStation].self, from: data) else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    private func load(_ key: String) -> [RFIStation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RFIStation].self, from: data) else { return [] }
        return decoded
    }

    private func save(_ stations: [RFIStation], _ key: String) {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
