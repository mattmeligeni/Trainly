//
//  DuoAdaptive.swift
//  Trainly
//
//  Layout adattivo per iPhone Duo e iPad (HIG «Designing for iPhone Duo», 9/9/2026).
//  Si decide con le size class e con la misura del contenitore, mai col tipo di
//  dispositivo o l'orientamento. Con la piega attiva (dispositivo aperto a metà)
//  niente contenuto essenziale sopra la piega: le colonne si separano lì.
//  Le API del Duo esistono da iOS 27 / 27.1: sotto, tutto si comporta come prima.
//

internal import SwiftUI

// MARK: - Regioni riservate

/// Piega (divisioni) e fotocamere (occlusioni) nello spazio della vista.
/// Prima di iOS 27.1 sono vuote.
struct DuoReservedRegions: Equatable {
    var divisions: [CGRect] = []
    var occlusions: [CGRect] = []

    static let none = DuoReservedRegions()

    init() {}

    init(_ proxy: GeometryProxy) {
        if #available(iOS 27.1, *) {
            // La piega solo se attiva (dispositivo parzialmente aperto). Le fotocamere
            // tutte, accese o no: l'alloggiamento della fotocamera interna c'è sempre.
            let bounds = CGRect(origin: .zero, size: proxy.size)
            divisions = proxy.reservedRegions(kind: .division).filter(\.isActive).map { bounds.intersection($0.frame) }
            occlusions = proxy.reservedRegions(kind: .occlusion).map(\.frame)
        }
    }

    /// La piega, se il dispositivo è parzialmente aperto e attraversa la vista.
    var fold: CGRect? { divisions.first { !$0.isNull && !$0.isEmpty } }

    /// Piega verticale (posa «libro») nello spazio della vista, se presente.
    var verticalFold: CGRect? {
        fold.flatMap { $0.height > $0.width ? $0 : nil }
    }
}

extension View {
    /// Legge le regioni riservate della vista senza cambiarne la misura.
    func readingReservedRegions(_ regions: Binding<DuoReservedRegions>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { regions.wrappedValue = DuoReservedRegions(proxy) }
                    .onChange(of: proxy.size) { regions.wrappedValue = DuoReservedRegions(proxy) }
                    .onChange(of: DuoReservedRegions(proxy)) { _, new in regions.wrappedValue = new }
            }
        }
    }
}

// MARK: - Due colonne

/// Due colonne affiancate con larghezza regolare (schermo interno di iPhone Duo,
/// iPad), una sotto l'altra con larghezza compatta. Con la piega attiva le colonne
/// finiscono ai due lati della piega vera (non per forza al centro: barre sul lato,
/// margini asimmetrici), così niente ci finisce sopra.
struct DuoTwoColumns<Leading: View, Trailing: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var spacing: CGFloat = 20
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var regions = DuoReservedRegions.none

    var body: some View {
        if sizeClass == .regular {
            Group {
                if let fold = regions.verticalFold {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: spacing) { leading }
                            .frame(width: max(0, fold.minX - spacing / 2), alignment: .top)
                        Color.clear.frame(width: fold.width + spacing, height: 1)
                        VStack(spacing: spacing) { trailing }
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    HStack(alignment: .top, spacing: spacing) {
                        VStack(spacing: spacing) { leading }
                            .frame(maxWidth: .infinity, alignment: .top)
                        VStack(spacing: spacing) { trailing }
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            .readingReservedRegions($regions)
        } else {
            VStack(spacing: spacing) {
                leading
                trailing
            }
        }
    }
}

// MARK: - Griglia

/// Griglia di schede: una colonna con larghezza compatta, due (numero pari, così
/// la piega cade fra le colonne) con larghezza regolare. Con la piega attiva le
/// colonne si allineano ai suoi bordi.
struct DuoGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    @State private var regions = DuoReservedRegions.none
    @State private var width: CGFloat = 0

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing) { content }
            .readingReservedRegions($regions)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var columns: [GridItem] {
        guard sizeClass == .regular else { return [GridItem(.flexible(), alignment: .top)] }
        if let fold = regions.verticalFold, width > 0 {
            let left = max(0, fold.minX - spacing / 2)
            let right = max(0, width - fold.maxX - spacing / 2)
            return [GridItem(.fixed(left), spacing: fold.width + spacing, alignment: .top),
                    GridItem(.fixed(right), alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: 2)
    }
}

// MARK: - Barre

/// Priorità di un elemento della barra quando lo spazio verticale non basta (barre
/// sul lato di iPhone Duo): quelli a priorità bassa vanno per primi nel menu di
/// troppo pieno. Da iOS 27.
enum DuoToolbarPriority { case low, high }

extension ToolbarContent {
    @ToolbarContentBuilder
    func visibilityPriorityIfAvailable(_ priority: DuoToolbarPriority) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            self.visibilityPriority(priority == .low ? .low : .high)
        } else {
            self
        }
    }
}

extension View {
    /// Barre orizzontali standard dove lo schermo è largo e più alto che largo
    /// (schermo interno di iPhone Duo in verticale, HIG: «The exception is the inner
    /// display in portrait, which has enough vertical space to keep standard
    /// horizontal bars»). Altrove il sistema decide (barre sul lato). Da iOS 27.1.
    func duoHorizontalBarsWhenTall() -> some View {
        modifier(DuoHorizontalBarsWhenTall())
    }
}

private struct DuoHorizontalBarsWhenTall: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tall = false

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 27.1, *) {
                content.toolbarVerticalBehavior(sizeClass == .regular && tall ? .disabled : .automatic)
            } else {
                content
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height > $0.size.width } action: { tall = $0 }
    }
}
