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

    /// When weekly `creditUsagePercent` is absent, mirror CLIProxy management UI:
    /// fall back to monthly included usage / limit as the displayed usage percent.
    func fillingMissingUsage(from monthly: MonthlyQuota?) -> WeeklyQuota {
        if usedPercent != nil { return self }
        guard let monthly, monthly.limitCents > 0 else { return self }

        let cappedUsed = min(max(monthly.usedCents, 0), monthly.limitCents)
        let percent = (Double(cappedUsed) / Double(monthly.limitCents) * 100.0).clampedPercentage
        return WeeklyQuota(
            usedPercent: percent,
            periodStart: periodStart,
            periodEnd: periodEnd,
            productUsage: productUsage
        )
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

struct Sub2APIUsage: Decodable, Sendable, Equatable {
    let mode: String
    let planName: String?
    let unit: String?
    let balance: Double?
    let remaining: Double?
    let quota: Sub2APIQuota?
    let subscription: Sub2APISubscription?
    let usage: Sub2APIUsageStats?

    init(
        mode: String,
        planName: String? = nil,
        unit: String? = nil,
        balance: Double? = nil,
        remaining: Double? = nil,
        quota: Sub2APIQuota? = nil,
        subscription: Sub2APISubscription? = nil,
        usage: Sub2APIUsageStats? = nil
    ) {
        self.mode = mode
        self.planName = planName
        self.unit = unit
        self.balance = balance
        self.remaining = remaining
        self.quota = quota
        self.subscription = subscription
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case mode, planName, unit, balance, remaining, quota, subscription, usage
    }

    var availableBalance: Double? {
        if let remaining { return max(remaining, 0) }
        if let remaining = quota?.remaining { return max(remaining, 0) }
        if let balance { return max(balance, 0) }
        if let monthlyLimit = subscription?.monthlyLimitUSD,
           let monthlyUsage = subscription?.monthlyUsageUSD {
            return max(monthlyLimit - monthlyUsage, 0)
        }
        if let weeklyLimit = subscription?.weeklyLimitUSD,
           let weeklyUsage = subscription?.weeklyUsageUSD {
            return max(weeklyLimit - weeklyUsage, 0)
        }
        if let dailyLimit = subscription?.dailyLimitUSD,
           let dailyUsage = subscription?.dailyUsageUSD {
            return max(dailyLimit - dailyUsage, 0)
        }
        return nil
    }

    /// Pre-formatted today's spend. Prefers the actual balance deduction
    /// (`usage.today.actual_cost`), falls back to list price `cost`, then
    /// subscription `daily_usage_usd`. Nil only when none are present.
    var dailyUsageText: String? {
        let value = usage?.today?.actualCost
            ?? usage?.today?.cost
            ?? subscription?.dailyUsageUSD
        return value.map { BalanceFormatter.string($0, unit: unit) }
    }
}

struct Sub2APIUsageStats: Decodable, Sendable, Equatable {
    let today: Sub2APIUsageWindow?
    let total: Sub2APIUsageWindow?
}

struct Sub2APIUsageWindow: Decodable, Sendable, Equatable {
    let actualCost: Double?
    let cost: Double?

    init(actualCost: Double?, cost: Double?) {
        self.actualCost = actualCost
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey {
        case actualCost = "actual_cost"
        case cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actualCost = try container.decodeIfPresent(FlexibleDouble.self, forKey: .actualCost)?.value
        cost = try container.decodeIfPresent(FlexibleDouble.self, forKey: .cost)?.value
    }
}

struct Sub2APIQuota: Decodable, Sendable, Equatable {
    let limit: Double?
    let used: Double?
    let remaining: Double?
}

struct Sub2APISubscription: Decodable, Sendable, Equatable {
    let dailyUsageUSD: Double?
    let dailyLimitUSD: Double?
    let weeklyUsageUSD: Double?
    let weeklyLimitUSD: Double?
    let monthlyUsageUSD: Double?
    let monthlyLimitUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case dailyUsageUSD = "daily_usage_usd"
        case dailyLimitUSD = "daily_limit_usd"
        case weeklyUsageUSD = "weekly_usage_usd"
        case weeklyLimitUSD = "weekly_limit_usd"
        case monthlyUsageUSD = "monthly_usage_usd"
        case monthlyLimitUSD = "monthly_limit_usd"
    }
}

// MARK: - DeepSeek 官方余额

struct DeepSeekBalance: Decodable, Sendable, Equatable {
    let isAvailable: Bool
    /// 选出的币种（余额信息为空时为 nil）。
    let currency: String?
    /// 选出的币种总余额（字符串转数值；余额信息为空时为 nil）。
    let totalBalance: Double?

    init(isAvailable: Bool, currency: String?, totalBalance: Double?) {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
    }

    /// `is_available == false` 且无任何余额时视为不可用。
    var unavailableMessage: String? {
        if !isAvailable && totalBalance == nil {
            return "账户不可用"
        }
        return nil
    }

    private struct Info: Decodable {
        let currency: String
        let totalBalance: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
            totalBalance = try container.decodeIfPresent(FlexibleDouble.self, forKey: .totalBalance)?.value
        }

        private enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        let infos = try container.decodeIfPresent([Info].self, forKey: .balanceInfos) ?? []

        // 币种选择顺序：USD 且 >0 → 任一 >0 → USD → 第一个。
        let selected = infos.first(where: { $0.currency.uppercased() == "USD" && ($0.totalBalance ?? 0) > 0 })
            ?? infos.first(where: { ($0.totalBalance ?? 0) > 0 })
            ?? infos.first(where: { $0.currency.uppercased() == "USD" })
            ?? infos.first
        currency = selected?.currency
        totalBalance = selected?.totalBalance
    }
}

/// One DeepSeek official API connection balance result.
struct DeepSeekUsageEntry: Identifiable, Sendable, Equatable {
    let connectionID: String
    let connectionName: String
    var usage: DeepSeekBalance?
    var error: String?

    var id: String { connectionID }
}

// MARK: - 统一余额行（Sub2API + DeepSeek）

/// Menu bar / widget shared balance row with a pre-formatted text.
struct BalanceEntry: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let balanceText: String?
    let planName: String?
    /// Pre-formatted today's spend (Sub2API only; nil for DeepSeek).
    let dailyUsageText: String?
    let error: String?

    init(
        id: String,
        name: String,
        balanceText: String? = nil,
        planName: String? = nil,
        dailyUsageText: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.balanceText = balanceText
        self.planName = planName
        self.dailyUsageText = dailyUsageText
        self.error = error
    }
}

enum BalanceFormatter {
    /// 常见币种用货币符号前缀：`$12.35`、`¥25.00`、`€12.35`、`£12.35`；
    /// 其他币种回退为 `12.35 XXX`（大写代码）。
    static func string(_ value: Double, unit: String?) -> String {
        let amount = String(format: "%.2f", value)
        let raw = (unit ?? "USD").trimmingCharacters(in: .whitespacesAndNewlines)
        if let symbol = Self.symbol(for: raw) {
            return "\(symbol)\(amount)"
        }
        let code = raw.isEmpty ? "USD" : raw.uppercased()
        return "\(amount) \(code)"
    }

    private static func symbol(for unit: String) -> String? {
        switch unit.uppercased() {
        case "USD", "US$", "$":
            return "$"
        case "CNY", "RMB", "¥":
            return "¥"
        case "EUR", "€":
            return "€"
        case "GBP", "£":
            return "£"
        default:
            return nil
        }
    }
}

struct AccountQuota: Identifiable, Sendable, Equatable {
    /// Owning CLIProxyAPI connection id (unique across multi-host configs).
    let connectionID: String
    /// User-facing CLIProxyAPI connection name for grouping / display.
    let connectionName: String
    let account: AuthAccount
    var weekly: WeeklyQuota?
    var monthly: MonthlyQuota?
    var errorMessage: String?

    /// Stable across hosts: connection + auth index (authIndex alone can collide).
    var id: String { "\(connectionID):\(account.authIndex)" }

    var isUnavailable: Bool {
        account.disabled || account.unavailable || weekly?.isExhausted == true
    }

    /// Absolute seconds from `now` to the weekly refresh/reset date.
    func distanceToRefresh(from now: Date = Date()) -> TimeInterval? {
        guard let periodEnd = weekly?.periodEnd else { return nil }
        return abs(periodEnd.timeIntervalSince(now))
    }

    init(
        connectionID: String = "",
        connectionName: String = "",
        account: AuthAccount,
        weekly: WeeklyQuota? = nil,
        monthly: MonthlyQuota? = nil,
        errorMessage: String? = nil
    ) {
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.account = account
        self.weekly = weekly
        self.monthly = monthly
        self.errorMessage = errorMessage
    }
}

/// One CLIProxyAPI host and its subscription rows (menu-bar section).
struct CLIProxyAccountGroup: Identifiable, Sendable, Equatable {
    let connectionID: String
    let connectionName: String
    var accounts: [AccountQuota]
    var error: String?

    var id: String { connectionID }
}

/// One Sub2API host usage result.
struct Sub2APIUsageEntry: Identifiable, Sendable, Equatable {
    let connectionID: String
    let connectionName: String
    var usage: Sub2APIUsage?
    var error: String?

    var id: String { connectionID }
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
