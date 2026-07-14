import Foundation

// Tutti i campi sono opzionali: le API cambiano forma a seconda dello stato del treno.
struct TrenitaliaResponse: Codable {
    let dataPartenza: String?
    let fermate: [TrenitaliaFermata]?
    let oraUltimoRilevamento: Int?
    let stazioneUltimoRilevamento: String?   // null se il treno non è ancora partito
    let hasProvvedimenti: Bool?
    let descOrientamento: [String]?
    let compOrientamento: [String]?     // composizione carrozze, es. "Executive in coda"
    let compNumeroTreno: String?        // es. " FR 8509" -> categoria + numero
    let subTitle: String?               // avviso cancellazione/modifica (se presente)
    let numeroTreno: Int?
    let origine: String?
    let destinazione: String?
    let orarioPartenza: Int?
    let orarioArrivo: Int?
    let ritardo: Int?
}

struct TrenitaliaFermata: Codable {
    let orientamento: String?   // null su regionali/intercity senza composizione
    let stazione: String?
    let programmata: Int?
    let effettiva: Int?       // null sulle fermate non ancora effettuate
    let ritardo: Int?
    // Orari separati arrivo/partenza (null sul capolinea corrispondente)
    let arrivo_teorico: Int?
    let partenza_teorica: Int?
    let arrivoReale: Int?
    let partenzaReale: Int?
    let ritardoArrivo: Int?
    let ritardoPartenza: Int?
    let actualFermataType: Int?   // 2 = fermata straordinaria
    let binarioEffettivoArrivoDescrizione: String?
    let binarioProgrammatoArrivoDescrizione: String?
    let binarioEffettivoPartenzaDescrizione: String?
    let binarioProgrammatoPartenzaDescrizione: String?
}
