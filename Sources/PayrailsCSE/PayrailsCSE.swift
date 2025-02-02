import Foundation
import JOSESwift

public enum FutureUsage: String, Codable {
    case Subscription
    case CardOnFile
    case UnscheduledCardOnFile
}

public struct TokenizeResponse: Codable {
    public let code: Int
    public let instrument: Instrument?
    public let errors: [PayrailsError]?
}

public struct PayrailsCSE {
    var cseConfig: CSEConfiguration?
    
    public init(data: String, version: String) {
        print("Initializing config of version", version)
        let config = parseConfig(data: data)
        cseConfig = config
    }
    
    func encryptCard(card: Card) throws -> String {
        let jsonCard = try JSONEncoder().encode(card)
        
        guard let cseConfig = cseConfig else {
            throw NSError(domain: "ConfigError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing Config"])
        }

        let header = JWEHeader(keyManagementAlgorithm: .RSAOAEP256, contentEncryptionAlgorithm: .A256CBCHS512)
        
        let publicKey: SecKey = try getPublicKey(cseConfig.tokenization.publicKey)
        let encrypter = Encrypter(keyManagementAlgorithm: .RSAOAEP256, contentEncryptionAlgorithm: .A256CBCHS512, encryptionKey: publicKey)!
        let jwe = try! JWE(header: header, payload: Payload(jsonCard), encrypter: encrypter)
        
        return jwe.compactSerializedString
    }
    
    public func tokenize(
        cardNumber: String,
        expiryMonth: String,
        expiryYear: String,
        holderName: String? = nil,
        securityCode: String? = nil,
        futureUsage: FutureUsage? = nil,
        storeInstrument: Bool? = true,
        completion: @escaping ((Result<TokenizeResponse, Error>) -> Void)
    ) throws -> Void {
        guard let cseConfig = cseConfig else {
            throw NSError(domain: "ConfigError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing Config"])
        }
        
        let card = Card(
            holderReference: cseConfig.holderReference,
            cardNumber: cardNumber,
            expiryMonth: expiryMonth,
            expiryYear: expiryYear,
            holderName: holderName,
            securityCode: securityCode
        )
        
        let encryptedCard = try! encryptCard(card: card)
        guard let tokenizeURL = URL(string: cseConfig.tokenization.links.tokenize.href) else {
            throw NSError(domain: "URLParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        
        var request = URLRequest(url: tokenizeURL)
        request.httpMethod = cseConfig.tokenization.links.tokenize.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cseConfig.token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-idempotency-key")
        
        let encoder = JSONEncoder()
        let jsonRequest = try encoder.encode(TokenizationRequest(
            id: cseConfig.tokenization.id,
            holderReference: cseConfig.holderReference,
            encryptedInstrumentDetails: encryptedCard,
            futureUsage: futureUsage,
            storeInstrument: storeInstrument
        ))
        request.httpBody = jsonRequest
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            do {
                if let error = error {
                    completion(.failure(error))
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "NetworkError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])))
                    return
                }
                
                guard let data = data else {
                    completion(.success(TokenizeResponse(code: httpResponse.statusCode, instrument: nil, errors: nil)))
                    return
                }
                
                if httpResponse.statusCode == 201 {
                    let jsonResponse = try JSONDecoder().decode(Instrument.self, from: data)
                
                    completion(.success(TokenizeResponse(code: httpResponse.statusCode, instrument: jsonResponse, errors: nil)))
                    return
                } else {
                    let jsonResponse = try JSONDecoder().decode(PayrailsErrorList.self, from: data)
                    completion(.success(TokenizeResponse(code: httpResponse.statusCode, instrument: nil, errors: jsonResponse.errors)))
                    return
                }
            } catch let error as NSError {
                completion(.failure(error))
                return
            }
        }
        
        task.resume()
    }
    
    private func parseConfig(data: String) -> CSEConfiguration {
        guard let decodedData = Data(base64Encoded: data) else {
            fatalError("Failed to decode Base64 data")
        }
        
        guard let config = try? JSONDecoder().decode(CSEConfiguration.self, from: decodedData) else {
            fatalError("Failed to parse CSEConfiguration")
        }
        
        return config
    }
    
    private func getPublicKey(_ publicKey: String) throws -> SecKey {
        let publicKeyData = Data(base64Encoded: publicKey)!
        
        var error: Unmanaged<CFError>?
        
        guard let kCFBooleanFalse = kCFBooleanFalse else {
            throw NSError(domain: "Error", code: 0, userInfo: [NSLocalizedDescriptionKey: "kCFBooleanFalse is nil"])
        }
        
        let options: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 2048,
            kSecReturnPersistentRef: kCFBooleanFalse
        ]
            
        guard let publicKeyRef = SecKeyCreateWithData(publicKeyData as CFData, options as CFDictionary, &error) else {
            fatalError("Failed to create public key: \(error!)")
        }
        
        return publicKeyRef
    }
}

struct Card: Codable {
    var holderReference: String
    var cardNumber: String
    var expiryMonth: String
    var expiryYear: String
    var holderName: String?
    var securityCode: String?
}

struct TokenizationRequest: Codable {
    let id: UUID
    let holderReference: String
    let encryptedInstrumentDetails: String
    let futureUsage: FutureUsage?
    let storeInstrument: Bool?
}

struct CSEConfiguration: Codable {
    let token: String
    let holderReference: String
    let tokenization: Tokenization
}

struct Tokenization: Codable {
    let id: UUID
    let publicKey: String
    let links: Links
}

struct Links: Codable {
    let tokenize: Link
}

struct Link: Codable {
    let method: String
    let href: String
}

public struct Instrument: Codable {
    public let id: UUID
    public let createdAt: String
    public let holderId: UUID
    public let holderReference: String?
    public let paymentMethod: PaymentMethodType
    public let status: InstrumentStatus
    public let description: String?
    public let data: InstrumentData
    public let providerData: CodableValue?
    public let futureUsage: String?
    public let fingerprint: String?
}

public struct InstrumentData: Codable {
    public let bin: String?
    public let holderName: String?
    public let scheme: String?
    public let suffix: String?
    public let expiryMonth: String?
    public let expiryYear: String?
    public let paymentToken: String?
    public let email: String?
}

public enum InstrumentStatus: String, Codable {
    case created
    case enabled
    case disabled
    case deleted
    case invalid
    case transient
}

public enum PaymentMethodType: String, Codable {
    case card
    case applePay
    case googlePay
    case klarna
    case klarna_paynow
    case klarna_account
    case payPal
    case undetermined
}

public struct PayrailsErrorList: Codable {
    public let errors: [PayrailsError]
}

public struct PayrailsError: Codable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let meta: CodableValue?
}

public struct CodableValue: Codable {
    let value: Any
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported CodableValue type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let doubleValue = value as? Double {
            try container.encode(doubleValue)
        } else if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        } else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported CodableValue type"))
        }
    }
}
