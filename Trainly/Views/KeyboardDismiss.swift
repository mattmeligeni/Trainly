//
//  KeyboardDismiss.swift
//  Trainly
//
//  Chiusura tastiera globale: un tap su un punto vuoto chiude la tastiera
//  ovunque nell'app, senza doverlo aggiungere a ogni campo.
//

internal import SwiftUI
internal import UIKit
internal import Combine

// MARK: - Sheet a prova di tastiera

/// Da applicare al contenuto di una sheet: impedisce la chiusura con lo swipe
/// mentre la tastiera è visibile (così lo swipe verso il basso chiude solo la
/// tastiera, non il modal).
private struct ModalKeyboardSafe: ViewModifier {
    @State private var keyboardVisible = false

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(keyboardVisible)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
    }
}

extension View {
    /// Per le sheet con campi di testo: niente chiusura con lo swipe mentre si scrive.
    func modalKeyboardSafe() -> some View { modifier(ModalKeyboardSafe()) }
}

/// Vista invisibile che installa il tap globale sulla finestra.
struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async { KeyboardDismissCoordinator.shared.install(on: view.window) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        KeyboardDismissCoordinator.shared.install(on: uiView.window)
    }
}

final class KeyboardDismissCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissCoordinator()

    private let tapName = "trainlyKeyboardDismissTap"
    private let panName = "trainlyKeyboardDismissPan"
    private var didDismissForCurrentPan = false

    func install(on window: UIWindow?) {
        guard let window else { return }
        let existing = window.gestureRecognizers?.compactMap { $0.name } ?? []

        if !existing.contains(tapName) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.name = tapName
            tap.cancelsTouchesInView = false   // non blocca i tocchi su pulsanti ecc.
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        if !existing.contains(panName) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.name = panName
            pan.cancelsTouchesInView = false   // non blocca lo scroll
            pan.delegate = self
            window.addGestureRecognizer(pan)
        }
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    // Swipe verso il basso (prevalentemente verticale) chiude la tastiera.
    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            didDismissForCurrentPan = false
        case .changed:
            guard !didDismissForCurrentPan else { return }
            let t = pan.translation(in: pan.view)
            if t.y > 40, abs(t.y) > abs(t.x) {
                dismissKeyboard()
                didDismissForCurrentPan = true
            }
        default:
            break
        }
    }

    // Convive con gli altri gesti (scroll, tap dei pulsanti…).
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // Non chiude se si tocca un campo di testo: così lo si può mettere a fuoco.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }
}
