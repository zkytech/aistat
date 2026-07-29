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

/// Raw management `api-call` envelope used when body shape varies by provider.
struct ManagementAPICallEnvelope: Decodable, Sendable {
    let statusCode: Int?
    let body: JSONValue

    private enum CodingKeys: String, CodingKey {
        case body
        case statusCode = "status_code"
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let code = try container.decodeIfPresent(Int.self, forKey: .statusCode) {
            statusCode = code
        } else if let code = try container.decodeIfPresent(Int.self, forKey: .status) {
            statusCode = code
        } else if let string = try container.decodeIfPresent(String.self, forKey: .statusCode)
                    ?? container.decodeIfPresent(String.self, forKey: .status),
                  let code = Int(string) {
            statusCode = code
        } else {
            statusCode = nil
        }
        body = try container.decode(JSONValue.self, forKey: .body)
    }

    var bodyData: Data {
        get throws { try body.jsonData() }
    }

    var errorSnippet: String {
        switch body {
        case .string(let string):
            return String(string.prefix(240))
        default:
            if let data = try? body.jsonData(),
               let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(240))
            }
            return "upstream error"
        }
    }

    var isSuccessfulStatus: Bool {
        guard let statusCode else { return true }
        return (200..<300).contains(statusCode)
    }
}

// MARK: - Codex (OpenAI) wham/usage

struct CodexUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let codeReviewRateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexNamedRateLimit]

    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case planTypeCamel = "planType"
        case rateLimit = "rate_limit"
        case rateLimitCamel = "rateLimit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case codeReviewRateLimitCamel = "codeReviewRateLimit"
        case additionalRateLimits = "additional_rate_limits"
        case additionalRateLimitsCamel = "additionalRateLimits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .planTypeCamel)
        rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimitCamel)
        codeReviewRateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .codeReviewRateLimit)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .codeReviewRateLimitCamel)
        additionalRateLimits = try container.decodeIfPresent([CodexNamedRateLimit].self, forKey: .additionalRateLimits)
            ?? container.decodeIfPresent([CodexNamedRateLimit].self, forKey: .additionalRateLimitsCamel)
            ?? []
    }

    func asWeeklyQuota() -> WeeklyQuota {
        var windows: [(label: String, window: CodexUsageWindow)] = []
        if let rateLimit {
            windows.append(contentsOf: rateLimit.labeledWindows(prefix: nil))
        }
        if let codeReviewRateLimit {
            windows.append(contentsOf: codeReviewRateLimit.labeledWindows(prefix: "代码审查"))
        }
        for item in additionalRateLimits {
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = (name?.isEmpty == false) ? name : "附加"
            windows.append(contentsOf: item.rateLimit.labeledWindows(prefix: prefix))
        }

        let products = windows.compactMap { entry -> ProductUsage? in
            guard let used = entry.window.usedPercent else { return nil }
            return ProductUsage(product: entry.label, usagePercent: used)
        }

        // Primary list metric: most constrained window (highest used %).
        let primary = windows
            .compactMap { entry -> (CodexUsageWindow, Double)? in
                guard let used = entry.window.usedPercent else { return nil }
                return (entry.window, used)
            }
            .max(by: { $0.1 < $1.1 })
            .map(\.0)

        return WeeklyQuota(
            usedPercent: primary?.usedPercent,
            periodStart: nil,
            periodEnd: primary?.resetDate,
            productUsage: products
        )
    }
}

struct CodexNamedRateLimit: Decodable, Sendable {
    let name: String?
    let rateLimit: CodexRateLimit

    private enum CodingKeys: String, CodingKey {
        case name
        case rateLimit = "rate_limit"
        case rateLimitCamel = "rateLimit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let value = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimitCamel) {
            rateLimit = value
        } else {
            rateLimit = try CodexRateLimit(from: decoder)
        }
    }
}

struct CodexRateLimit: Decodable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case limitReachedCamel = "limitReached"
        case primaryWindow = "primary_window"
        case primaryWindowCamel = "primaryWindow"
        case secondaryWindow = "secondary_window"
        case secondaryWindowCamel = "secondaryWindow"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed)
        limitReached = try container.decodeIfPresent(Bool.self, forKey: .limitReached)
            ?? container.decodeIfPresent(Bool.self, forKey: .limitReachedCamel)
        primaryWindow = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindow)
            ?? container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindowCamel)
        secondaryWindow = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindow)
            ?? container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindowCamel)
    }

    func labeledWindows(prefix: String?) -> [(label: String, window: CodexUsageWindow)] {
        var result: [(String, CodexUsageWindow)] = []
        if let primaryWindow {
            result.append((windowLabel(kind: primaryWindow.kindLabel(default: "5 小时限额"), prefix: prefix), primaryWindow))
        }
        if let secondaryWindow {
            result.append((windowLabel(kind: secondaryWindow.kindLabel(default: "周限额"), prefix: prefix), secondaryWindow))
        }
        return result
    }

    private func windowLabel(kind: String, prefix: String?) -> String {
        if let prefix, !prefix.isEmpty {
            return "\(prefix) \(kind)"
        }
        return kind
    }
}

struct CodexUsageWindow: Decodable, Sendable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case usedPercentCamel = "usedPercent"
        case limitWindowSeconds = "limit_window_seconds"
        case limitWindowSecondsCamel = "limitWindowSeconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAfterSecondsCamel = "resetAfterSeconds"
        case resetAt = "reset_at"
        case resetAtCamel = "resetAt"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try Self.decodeClampedPercent(container, .usedPercent, .usedPercentCamel)
        limitWindowSeconds = try Self.decodeDouble(container, .limitWindowSeconds, .limitWindowSecondsCamel)
        resetAfterSeconds = try Self.decodeDouble(container, .resetAfterSeconds, .resetAfterSecondsCamel)
        resetAt = try Self.decodeDouble(container, .resetAt, .resetAtCamel)
    }

    var resetDate: Date? {
        if let resetAt {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfterSeconds {
            return Date().addingTimeInterval(resetAfterSeconds)
        }
        return nil
    }

    func kindLabel(default fallback: String) -> String {
        guard let seconds = limitWindowSeconds else { return fallback }
        if abs(seconds - 18_000) < 1 { return "5 小时限额" }
        if abs(seconds - 604_800) < 1 { return "周限额" }
        if seconds >= 2_419_200 && seconds <= 2_678_400 { return "月度限额" }
        if seconds >= 86_400 {
            let days = Int((seconds / 86_400).rounded())
            return "\(days) 天限额"
        }
        let hours = max(Int((seconds / 3_600).rounded()), 1)
        return "\(hours) 小时限额"
    }

    private static func decodeClampedPercent(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ alt: CodingKeys
    ) throws -> Double? {
        if let value = try decodeDouble(container, key, alt) {
            return min(max(value, 0), 100)
        }
        return nil
    }

    private static func decodeDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ alt: CodingKeys
    ) throws -> Double? {
        if let value = try container.decodeIfPresent(Double.self, forKey: key)
            ?? container.decodeIfPresent(Double.self, forKey: alt) {
            return value
        }
        if let string = try container.decodeIfPresent(String.self, forKey: key)
            ?? container.decodeIfPresent(String.self, forKey: alt),
           let value = Double(string) {
            return value
        }
        if let int = try container.decodeIfPresent(Int.self, forKey: key)
            ?? container.decodeIfPresent(Int.self, forKey: alt) {
            return Double(int)
        }
        return nil
    }
}

// MARK: - Claude oauth/usage

struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDayOAuthApps: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?
    let sevenDaySonnet: ClaudeUsageWindow?
    let sevenDayCowork: ClaudeUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
    }

    func asWeeklyQuota() -> WeeklyQuota {
        let labeled: [(String, ClaudeUsageWindow)] = [
            ("5 小时限额", fiveHour),
            ("7 天限额", sevenDay),
            ("7 天 OAuth 应用", sevenDayOAuthApps),
            ("7 天 Opus", sevenDayOpus),
            ("7 天 Sonnet", sevenDaySonnet),
            ("7 天 Cowork", sevenDayCowork)
        ].compactMap { label, window in
            guard let window else { return nil }
            return (label, window)
        }

        let products = labeled.map {
            ProductUsage(product: $0.0, usagePercent: $0.1.utilization)
        }

        let primary = labeled
            .map { ($0.1, $0.1.utilization) }
            .max(by: { $0.1 < $1.1 })
            .map(\.0)

        // Prefer seven-day reset when primary is five-hour with equal usage pressure;
        // still pick the tightest remaining for the list headline.
        return WeeklyQuota(
            usedPercent: primary?.utilization,
            periodStart: nil,
            periodEnd: primary?.resetDate,
            productUsage: products
        )
    }
}

struct ClaudeUsageWindow: Decodable, Sendable {
    let utilization: Double
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Double.self, forKey: .utilization) {
            utilization = min(max(value, 0), 100)
        } else if let string = try? container.decode(String.self, forKey: .utilization),
                  let value = Double(string) {
            utilization = min(max(value, 0), 100)
        } else if let int = try? container.decode(Int.self, forKey: .utilization) {
            utilization = min(max(Double(int), 0), 100)
        } else {
            utilization = 0
        }

        if let dateString = try? container.decode(String.self, forKey: .resetsAt) {
            resetsAt = APIDateParser.date(from: dateString)
        } else if let timestamp = try? container.decode(Double.self, forKey: .resetsAt) {
            resetsAt = Date(timeIntervalSince1970: timestamp)
        } else if let timestamp = try? container.decode(Int.self, forKey: .resetsAt) {
            resetsAt = Date(timeIntervalSince1970: Double(timestamp))
        } else {
            resetsAt = nil
        }
    }

    var resetDate: Date? { resetsAt }
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

    func jsonData() throws -> Data {
        switch self {
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Body string is not UTF-8")
                )
            }
            return data
        case .null:
            return Data("null".utf8)
        default:
            return try JSONSerialization.data(withJSONObject: rawValue, options: [])
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
