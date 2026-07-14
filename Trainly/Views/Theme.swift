//
//  Theme.swift
//  Trainly
//
//  Colori condivisi della UI.
//

internal import SwiftUI

extension Color {
    /// Sfondo chiaro fisso per i riquadri dei loghi treno.
    /// Resta chiaro anche in dark mode: molti loghi hanno testo scuro
    /// e su fondo scuro risulterebbero illeggibili.
    static let logoTile = Color(white: 0.95)
}
