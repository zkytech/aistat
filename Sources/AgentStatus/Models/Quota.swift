import Foundation

struct ProductUsage: Decodable, Sendable, Equatable, Identifiable {
    let product: String
    let usagePercent: Double?

    var id: String { product }

    var remainingPercent: Double? {
        usagePercent.map { (100 - $0).clampedPercentage }
    }

    init(product: String, usagePercent: Double?) {
        self.product = product
        self.usagePercent = usagePercent.map { $0.clampedPercentage }
    }

    private enum CodingKeys: String, CodingKey {
        case product, usagePercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        product = try container.decode(String.self, forKey: .product)
        if container.contains(.usagePercent), try !container.decodeNil(forKey: .usagePercent) {
            usagePercent = try container.decode(FlexibleDouble.self, forKey: .usagePercent).value.clampedPercentage
        } else {
            usagePercent = nil
        }
    }
}

struct WeeklyQuota: Sendable, Equatable {
    let usedPercent: Double?
    let periodStart: Date?
    let periodEnd: Date?
    let productUsage: [ProductUsage]

    var remainingPercent: Double? {
        usedPercent.map { (100 - $0).clampedPercentage }
    }

    var isExhausted: Bool {
        remainingPercent.map { $0 <= 0 } ?? false
    }
}

struct MonthlyQuota: Sendable, Equatable {
    let limitCents: Int
    let usedCents: Int

    var remainingCents: Int {
        max(limitCents - usedCents, 0)
    }

    var remainingPercent: Double? {
        guard limitCents > 0 else { return nil }
        return (Double(remainingCents) / Double(limitCents) * 100.0).clampedPercentage
    }
}

struct AccountQuota: Identifiable, Sendable, Equatable {
    let account: AuthAccount
    var weekly: WeeklyQuota?
    var monthly: MonthlyQuota?
    var errorMessage: String?

    var id: String { account.id }

    var isUnavailable: Bool {
        account.disabled || account.unavailable || weekly?.isExhausted == true
    }

    /// Absolute seconds from `now` to the weekly refresh/reset date.
    func distanceToRefresh(from now: Date = Date()) -> TimeInterval? {
        guard let periodEnd = weekly?.periodEnd else { return nil }
        return abs(periodEnd.timeIntervalSince(now))
    }
}

enum DisplayDateFormatter {
    /// Local wall-clock format: `2026-07-29 12:01:00`
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

enum AccountQuotaSorter {
    /// Closer to refresh date first; missing dates last; stable by display name + authIndex.
    static func sortByRefreshProximity(_ items: [AccountQuota], now: Date = Date()) -> [AccountQuota] {
        items.sorted { lhs, rhs in
            let leftDistance = lhs.distanceToRefresh(from: now)
            let rightDistance = rhs.distanceToRefresh(from: now)

            switch (leftDistance, rightDistance) {
            case let (l?, r?):
                if l != r { return l < r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            let leftName = lhs.account.displayName.localizedCaseInsensitiveCompare(rhs.account.displayName)
            if leftName != .orderedSame {
                return leftName == .orderedAscending
            }
            return lhs.account.authIndex < rhs.account.authIndex
        }
    }

    /// Higher priority value is preferred by CLIProxyAPI.
    static func prioritiesByProximity(_ items: [AccountQuota], now: Date = Date()) -> [(name: String, priority: Int)] {
        let sorted = sortByRefreshProximity(items, now: now)
        let count = sorted.count
        return sorted.enumerated().map { index, item in
            (name: item.account.managementName, priority: count - index)
        }
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a number or numeric string")
            )
        }
    }
}

private extension Double {
    var clampedPercentage: Double { min(max(self, 0), 100) }
}
