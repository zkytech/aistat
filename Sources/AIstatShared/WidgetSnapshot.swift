import Foundation

/// Shared, lightweight snapshot for WidgetKit. Keeps secrets out of the container.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var isConfigured: Bool
    public var globalError: String?
    public var accounts: [WidgetAccountEntry]
    public var sub2Entries: [WidgetSub2Entry]
    /// Available named connections for per-widget App Intent pickers (no secrets).
    public var sources: [WidgetSourceInfo]
    /// Legacy single Sub2 fields kept for decode compatibility with older host builds.
    public var sub2BalanceText: String?
    public var sub2PlanName: String?
    public var sub2Error: String?

    public init(
        updatedAt: Date = Date(),
        isConfigured: Bool = false,
        globalError: String? = nil,
        accounts: [WidgetAccountEntry] = [],
        sub2Entries: [WidgetSub2Entry] = [],
        sources: [WidgetSourceInfo] = [],
        sub2BalanceText: String? = nil,
        sub2PlanName: String? = nil,
        sub2Error: String? = nil
    ) {
        self.updatedAt = updatedAt
        self.isConfigured = isConfigured
        self.globalError = globalError
        self.accounts = accounts
        self.sub2Entries = sub2Entries
        self.sources = sources
        self.sub2BalanceText = sub2BalanceText
        self.sub2PlanName = sub2PlanName
        self.sub2Error = sub2Error
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt, isConfigured, globalError, accounts, sub2Entries, sources
        case sub2BalanceText, sub2PlanName, sub2Error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isConfigured = try container.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false
        globalError = try container.decodeIfPresent(String.self, forKey: .globalError)
        accounts = try container.decodeIfPresent([WidgetAccountEntry].self, forKey: .accounts) ?? []
        sub2Entries = try container.decodeIfPresent([WidgetSub2Entry].self, forKey: .sub2Entries) ?? []
        sources = try container.decodeIfPresent([WidgetSourceInfo].self, forKey: .sources) ?? []
        sub2BalanceText = try container.decodeIfPresent(String.self, forKey: .sub2BalanceText)
        sub2PlanName = try container.decodeIfPresent(String.self, forKey: .sub2PlanName)
        sub2Error = try container.decodeIfPresent(String.self, forKey: .sub2Error)

        // Migrate legacy single Sub2 fields into sub2Entries when needed.
        if sub2Entries.isEmpty,
           sub2BalanceText != nil || sub2PlanName != nil || sub2Error != nil {
            sub2Entries = [
                WidgetSub2Entry(
                    id: "legacy",
                    name: "Sub2API",
                    balanceText: sub2BalanceText,
                    planName: sub2PlanName,
                    error: sub2Error
                )
            ]
        }

        // Infer sources from entries when older hosts omitted the catalog.
        if sources.isEmpty {
            var inferred: [WidgetSourceInfo] = []
            var seen = Set<String>()
            for account in accounts {
                guard let sourceID = account.sourceID, !sourceID.isEmpty else { continue }
                guard seen.insert(sourceID).inserted else { continue }
                inferred.append(
                    WidgetSourceInfo(
                        id: sourceID,
                        name: account.sourceName ?? "CLIProxyAPI",
                        kind: WidgetSourceKind.cliproxy.rawValue
                    )
                )
            }
            for entry in sub2Entries {
                guard seen.insert(entry.id).inserted else { continue }
                inferred.append(
                    WidgetSourceInfo(
                        id: entry.id,
                        name: entry.name,
                        kind: WidgetSourceKind.sub2api.rawValue
                    )
                )
            }
            sources = inferred
        }
    }

    public static let empty = WidgetSnapshot()

    /// Primary Sub2 row for compact chrome (first successful, else first error, else first).
    public var primarySub2Entry: WidgetSub2Entry? {
        if let ok = sub2Entries.first(where: { $0.balanceText != nil }) {
            return ok
        }
        if let err = sub2Entries.first(where: { $0.error != nil }) {
            return err
        }
        return sub2Entries.first
    }

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
        !accounts.isEmpty || !sub2Entries.isEmpty
    }

    /// Filter by per-widget App Intent selection. Empty selection → empty payload with `isConfigured = false`.
    public func filtered(
        cliProxySourceIDs: Set<String>,
        sub2SourceIDs: Set<String>
    ) -> WidgetSnapshot {
        let hasSelection = !cliProxySourceIDs.isEmpty || !sub2SourceIDs.isEmpty
        guard hasSelection else {
            var empty = self
            empty.isConfigured = false
            empty.accounts = []
            empty.sub2Entries = []
            empty.sub2BalanceText = nil
            empty.sub2PlanName = nil
            empty.sub2Error = nil
            return empty
        }

        var next = self
        next.isConfigured = true
        next.accounts = accounts.filter { entry in
            guard let sourceID = entry.sourceID else { return false }
            return cliProxySourceIDs.contains(sourceID)
        }
        next.sub2Entries = sub2Entries.filter { sub2SourceIDs.contains($0.id) }

        let primary = next.primarySub2Entry
        next.sub2BalanceText = primary?.balanceText
        next.sub2PlanName = primary?.planName
        next.sub2Error = primary?.error
        return next
    }
}

public enum WidgetSourceKind: String, Codable, Sendable {
    case cliproxy
    case sub2api
}

/// Named data source for widget configuration pickers (no credentials).
public struct WidgetSourceInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var sourceKind: WidgetSourceKind {
        WidgetSourceKind(rawValue: kind) ?? .cliproxy
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch sourceKind {
        case .cliproxy: return "CLIProxyAPI"
        case .sub2api: return "Sub2API"
        }
    }
}

public struct WidgetSub2Entry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var balanceText: String?
    public var planName: String?
    public var error: String?

    public init(
        id: String,
        name: String,
        balanceText: String? = nil,
        planName: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.balanceText = balanceText
        self.planName = planName
        self.error = error
    }

    public var displayLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sub2API" : trimmed
    }
}

public struct WidgetAccountEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var displayName: String
    /// CLIProxyAPI connection id (for per-widget filtering).
    public var sourceID: String?
    /// CLIProxyAPI connection name (optional for older snapshots).
    public var sourceName: String?
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
        sourceID: String? = nil,
        sourceName: String? = nil,
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
        self.sourceID = sourceID
        self.sourceName = sourceName
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
