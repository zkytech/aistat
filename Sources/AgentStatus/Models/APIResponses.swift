import Foundation

struct AuthFilesResponse: Decodable, Sendable {
    let accounts: [AuthAccount]

    private enum CodingKeys: String, CodingKey {
        case files, data
        case authFiles = "auth_files"
    }

    init(from decoder: Decoder) throws {
        if let accounts = try? decoder.singleValueContainer().decode([AuthAccount].self) {
            self.accounts = accounts
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let accounts = try container.decodeIfPresent([AuthAccount].self, forKey: .files)
            ?? container.decodeIfPresent([AuthAccount].self, forKey: .authFiles)
            ?? container.decodeIfPresent([AuthAccount].self, forKey: .data) {
            self.accounts = accounts
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing auth file list")
        )
    }
}

struct APIProxyResponse: Decodable, Sendable {
    let body: BillingResponse

    private enum CodingKeys: String, CodingKey {
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode body once via JSONValue to support object or JSON-string payloads.
        let value = try container.decode(JSONValue.self, forKey: .body)
        body = try BillingResponse.decode(from: value)
    }
}

struct BillingResponse: Decodable, Sendable {
    let config: BillingConfig

    static func decode(from value: JSONValue) throws -> BillingResponse {
        switch value {
        case .object:
            let data = try JSONSerialization.data(withJSONObject: value.rawValue)
            return try JSONDecoder().decode(BillingResponse.self, from: data)
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Body string is not UTF-8")
                )
            }
            return try JSONDecoder().decode(BillingResponse.self, from: data)
        default:
            throw DecodingError.typeMismatch(
                BillingResponse.self,
                DecodingError.Context(codingPath: [], debugDescription: "Expected object or JSON string body")
            )
        }
    }
}

struct BillingConfig: Decodable, Sendable {
    let creditUsagePercent: Double?
    let currentPeriod: BillingPeriod?
    let productUsage: [ProductUsage]
    let monthlyLimit: MoneyValue?
    let used: MoneyValue?

    private enum CodingKeys: String, CodingKey {
        case creditUsagePercent, currentPeriod, productUsage, monthlyLimit, used
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Double.self, forKey: .creditUsagePercent) {
            creditUsagePercent = min(max(value, 0), 100)
        } else if let string = try container.decodeIfPresent(String.self, forKey: .creditUsagePercent),
                  let value = Double(string) {
            creditUsagePercent = min(max(value, 0), 100)
        } else {
            creditUsagePercent = nil
        }
        currentPeriod = try container.decodeIfPresent(BillingPeriod.self, forKey: .currentPeriod)
        productUsage = try container.decodeIfPresent([ProductUsage].self, forKey: .productUsage) ?? []
        monthlyLimit = try container.decodeIfPresent(MoneyValue.self, forKey: .monthlyLimit)
        used = try container.decodeIfPresent(MoneyValue.self, forKey: .used)
    }

    var weeklyQuota: WeeklyQuota {
        WeeklyQuota(
            usedPercent: creditUsagePercent,
            periodStart: currentPeriod?.start,
            periodEnd: currentPeriod?.end,
            productUsage: productUsage
        )
    }

    var monthlyQuota: MonthlyQuota? {
        guard let limit = monthlyLimit?.val, let used = used?.val else { return nil }
        return MonthlyQuota(limitCents: limit, usedCents: used)
    }
}

struct BillingPeriod: Decodable, Sendable {
    let start: Date?
    let end: Date?

    private enum CodingKeys: String, CodingKey {
        case start, end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = Self.decodeDate(from: container, forKey: .start)
        end = Self.decodeDate(from: container, forKey: .end)
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Date? {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return APIDateParser.date(from: value)
    }
}

enum APIDateParser {
    static func date(from value: String) -> Date? {
        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value) {
            return date
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }

        // Handle timestamps with 1...6 fractional digits, e.g. 2026-07-28T14:25:29.139195+00:00
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in patterns {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

struct MoneyValue: Decodable, Sendable {
    let val: Int
}

/// Single-pass JSON tree used to branch on object vs string `body` without double-decoding a key.
enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var rawValue: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.rawValue)
        case .array(let array):
            return array.map(\.rawValue)
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
