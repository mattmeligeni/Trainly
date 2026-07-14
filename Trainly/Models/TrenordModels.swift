import Foundation

// MARK: - Modelli Trenord
// Generati da Esempi API/trenord.json

typealias TrenordResponse = [TrenordSolution]

struct TrenordSolution: Codable {
    let date: String?
    let depTime: String?
    let depStation: TrenordStation?
    let arrTime: String?
    let arrStation: TrenordStation?
    let duration: String?
    let change: String?
    let journeyList: [TrenordJourney]?
    let delay: Int?          // null se il ritardo non è ancora definito
    let cancelled: Bool?

    enum CodingKeys: String, CodingKey {
        case date
        case depTime = "dep_time"
        case depStation = "dep_station"
        case arrTime = "arr_time"
        case arrStation = "arr_station"
        case duration
        case change
        case journeyList = "journey_list"
        case delay
        case cancelled
    }
}

struct TrenordStation: Codable {
    let stationOriName: String?

    enum CodingKeys: String, CodingKey {
        case stationOriName = "station_ori_name"
    }
}

struct TrenordJourney: Codable {
    let train: TrenordTrain?
    let passList: [TrenordPass]?

    enum CodingKeys: String, CodingKey {
        case train
        case passList = "pass_list"
    }
}

struct TrenordTrain: Codable {
    let trainId: String?
    let trainName: String?
    let category: String?      // es. "RE", "R", "S"

    enum CodingKeys: String, CodingKey {
        case trainId = "train_id"
        case trainName = "train_name"
        case category = "train_category"
    }
}

struct TrenordPass: Codable {
    let arrTime: String?
    let depTime: String?
    let station: TrenordStation?
    let actualData: TrenordActualData?
    let platform: String?
    let isActualPlatform: Bool?

    enum CodingKeys: String, CodingKey {
        case arrTime = "arr_time"
        case depTime = "dep_time"
        case station
        case actualData = "actual_data"
        case platform
        case isActualPlatform = "is_actual_platform"
    }
}

struct TrenordActualData: Codable {
    let actualStationName: String?
    let depActualTime: String?
    let arrActualTime: String?
    let arrEstimatedTime: String?
    let depEstimatedTime: String?

    enum CodingKeys: String, CodingKey {
        case actualStationName = "actual_station_name"
        case depActualTime = "dep_actual_time"
        case arrActualTime = "arr_actual_time"
        case arrEstimatedTime = "arr_estimated_time"
        case depEstimatedTime = "dep_estimated_time"
    }
}
