import Foundation

/// Shared, lightweight snapshot for WidgetKit. Keeps secrets out of the container.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var isConfigured: Bool
    public var globalError: String?
    public var accounts: [WidgetAccountEntry]
    public var sub2BalanceText: String?
    public var sub2PlanName: String?
    public var sub2Error: String?

    public init(
        updatedAt: Date = Date(),
        isConfigured: Bool = false,
        globalError: String? = nil,
        accounts: [WidgetAccountEntry] = [],
        sub2BalanceText: String? = nil,
        sub2PlanName: String? = nil,
        sub2Error: String? = nil
    ) {
        self.updatedAt = updatedAt
        self.isConfigured = isConfigured
        self.globalError = globalError
        self.accounts = accounts
        self.sub2BalanceText = sub2BalanceText
        self.sub2PlanName = sub2PlanName
        self.sub2Error = sub2Error
    }

    public static let empty = WidgetSnapshot()

    /// Account with the lowest weekly remaining (active only). Mirrors menu-bar title logic.
    public var tightestAccount: WidgetAccountEntry? {
        accounts
            .filter { !$0.isDisabled && !$0.isUnavailable }
            .compactMap { entry -> (WidgetAccountEntry, Double)? in
                guard let remaining = entry.remainingPercent else { return nil }
                return (entry, remaining)
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    public var hasAnyData: Bool {
        !accounts.isEmpty || sub2BalanceText != nil || sub2Error != nil
    }
}

public struct WidgetAccountEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var displayName: String
    public var status: String
    public var remainingPercent: Double?
    public var periodEnd: Date?
    public var errorMessage: String?
    public var isDisabled: Bool
    public var isUnavailable: Bool

    public init(
        id: String,
        provider: String,
        displayName: String,
        status: String,
        remainingPercent: Double? = nil,
        periodEnd: Date? = nil,
        errorMessage: String? = nil,
        isDisabled: Bool = false,
        isUnavailable: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.status = status
        self.remainingPercent = remainingPercent
        self.periodEnd = periodEnd
        self.errorMessage = errorMessage
        self.isDisabled = isDisabled
        self.isUnavailable = isUnavailable
    }

    public var providerKind: WidgetProviderKind {
        WidgetProviderKind.resolve(from: provider)
    }
}

public enum WidgetAccountPresentation {
    public static let mediumLimit = 3
    public static let largeLimit = 5
    /// Large dashboard (ring grid): 2×3 fits systemLarge chrome cleanly.
    public static let dashboardLimit = 6

    public static func rows(
        from accounts: [WidgetAccountEntry],
        limit: Int
    ) -> [WidgetAccountEntry] {
        Array(accounts.prefix(max(0, limit)))
    }
}

public enum WidgetProviderKind: String, Sendable {
    case openai
    case claude
    case grok
    case unknown

    public static func resolve(from raw: String) -> WidgetProviderKind {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai", "codex":
            return .openai
        case "claude", "anthropic":
            return .claude
        case "xai", "grok":
            return .grok
        default:
            return .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .unknown: return "账号"
        }
    }

    /// Resource stem matching menu-bar `ProviderIcon-*.png` assets.
    public var iconResourceName: String? {
        switch self {
        case .openai, .claude, .grok:
            return "ProviderIcon-\(rawValue)"
        case .unknown:
            return nil
        }
    }

    /// SF Symbol fallback when the brand PNG is unavailable.
    public var systemImage: String {
        switch self {
        case .openai: return "circle.hexagongrid.fill"
        case .claude: return "sparkles"
        case .grok: return "bolt.fill"
        case .unknown: return "person.crop.circle"
        }
    }
}

/// Compact reset countdown shared by main app list and widgets.
public enum WidgetResetFormatter {
    /// e.g. `2天4时`, `3时12分`, `45分`, `已到期`
    public static func string(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 {
            return "已到期"
        }

        let totalMinutes = Int(seconds.rounded(.down)) / 60
        if totalMinutes < 1 {
            return "即将重置"
        }

        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 {
                return "\(days)天\(hours)时"
            }
            return "\(days)天"
        }
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)时\(minutes)分"
            }
            return "\(hours)时"
        }
        return "\(minutes)分"
    }
}

public enum WidgetRemainingStyle {
    /// Status-band thresholds for remaining % (not sole indicator — always show digits).
    public static func band(for remaining: Double?) -> Band {
        guard let remaining else { return .unknown }
        if remaining <= 0 { return .critical }
        if remaining <= 20 { return .warning }
        return .healthy
    }

    public enum Band: String, Sendable {
        case healthy
        case warning
        case critical
        case unknown
    }
}
