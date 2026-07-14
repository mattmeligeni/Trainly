//
//  trenordRequest.swift
//  Trainly
//
//  Servizio Trenord (www.trenord.it/mia/bff).
//  La risposta è cifrata AES-256-ECB: va decifrata e poi decodificata
//  come array [TrenordSolution] (vedi TrenordModels.swift).
//

import Foundation
import CommonCrypto

// MARK: - Errori
enum TrenordError: Error {
    case invalidURL
    case invalidResponse
    case decryptionFailed
    case trainNotFound
    case decodingFailed(Error)
}

// MARK: - Servizio Trenord
enum TrenordService {

    private static let key = "CHIAVE_TRENORD_RIMOSSA"
    private static let baseURL = "https://www.trenord.it/mia/bff/"

    /// Percorso normalizzato pronto per la UI (TrainView).
    static func journey(numeroTreno: String, date: String? = nil) async throws -> TrainJourney {
        let response = try await soluzioni(trainId: numeroTreno, date: date)
        guard let journey = TrainJourney(trenord: response) else {
            throw TrenordError.trainNotFound
        }
        return journey
    }

    /// Scarica, decifra e decodifica la risposta Trenord.
    static func soluzioni(trainId: String, date: String? = nil) async throws -> TrenordResponse {
        let queryDate = date ?? Self.todayString()
        let numero = trainId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(baseURL)train/\(numero)?date=\(queryDate)") else {
            throw TrenordError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.trenord.it/linee-e-orari/circolazione/tempo-reale/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TrenordError.invalidResponse
        }

        guard let decrypted = decrypt(data: data) else {
            throw TrenordError.decryptionFailed
        }

        do {
            return try JSONDecoder().decode(TrenordResponse.self, from: decrypted)
        } catch {
            throw TrenordError.decodingFailed(error)
        }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Decrittazione AES-256-ECB (chiave = SHA256 della passphrase)
    private static func decrypt(data: Data) -> Data? {
        guard let keyData = key.data(using: .utf8) else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(keyData.count), &hash)
        }
        let aesKey = Data(hash)

        let cryptLength = size_t(data.count)
        var cryptData = Data(count: cryptLength)

        var numBytesDecrypted: size_t = 0
        let status = cryptData.withUnsafeMutableBytes { cryptBytes in
            data.withUnsafeBytes { dataBytes in
                aesKey.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        kCCKeySizeAES256,
                        nil, // ECB non usa IV
                        dataBytes.baseAddress,
                        data.count,
                        cryptBytes.baseAddress,
                        cryptLength,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        cryptData.removeSubrange(numBytesDecrypted..<cryptData.count)
        return cryptData
    }
}
