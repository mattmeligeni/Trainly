import Foundation

// MARK: - Modelli Italo
// Endpoint: italoinviaggio.italotreno.com/api/RicercaTrenoService?TrainNumber=...

struct ItaloResponse: Codable {
    let isEmpty: Bool?
    let lastUpdate: String?                    // null quando IsEmpty
    let trainSchedule: ItaloTrainSchedule?     // null quando IsEmpty

    enum CodingKeys: String, CodingKey {
        case isEmpty = "IsEmpty"
        case lastUpdate = "LastUpdate"
        case trainSchedule = "TrainSchedule"
    }
}

struct ItaloTrainSchedule: Codable {
    let trainNumber: String?
    let rfiTrainNumber: String?               // numero treno lato RFI
    let departureDate: String?                // orario partenza origine, es. "11:40"
    let departureStationDescription: String?
    let arrivalDate: String?
    let arrivalStationDescription: String?
    let distruption: ItaloDistruption?
    let stazioniFerme: [ItaloStazione]?       // fermate già effettuate
    let stazioniNonFerme: [ItaloStazione]?    // fermate da effettuare

    enum CodingKeys: String, CodingKey {
        case trainNumber = "TrainNumber"
        case rfiTrainNumber = "RfiTrainNumber"
        case departureDate = "DepartureDate"
        case departureStationDescription = "DepartureStationDescription"
        case arrivalDate = "ArrivalDate"
        case arrivalStationDescription = "ArrivalStationDescription"
        case distruption = "Distruption"
        case stazioniFerme = "StazioniFerme"
        case stazioniNonFerme = "StazioniNonFerme"
    }
}

struct ItaloDistruption: Codable {
    let delayAmount: Int?
    let warning: Bool?          // presenza di avvisi/anomalie
    let runningState: Int?      // stato di marcia del treno

    enum CodingKeys: String, CodingKey {
        case delayAmount = "DelayAmount"
        case warning = "Warning"
        case runningState = "RunningState"
    }
}

struct ItaloStazione: Codable {
    let locationDescription: String?
    let estimatedDepartureTime: String?
    let actualDepartureTime: String?
    let estimatedArrivalTime: String?
    let actualArrivalTime: String?
    let actualArrivalPlatform: String?    // es. "16" (stringa!), null se non assegnato
    let stationNumber: Int?

    enum CodingKeys: String, CodingKey {
        case locationDescription = "LocationDescription"
        case estimatedDepartureTime = "EstimatedDepartureTime"
        case actualDepartureTime = "ActualDepartureTime"
        case estimatedArrivalTime = "EstimatedArrivalTime"
        case actualArrivalTime = "ActualArrivalTime"
        case actualArrivalPlatform = "ActualArrivalPlatform"
        case stationNumber = "StationNumber"
    }
}
