import Foundation

// MARK: - Named connections

/// One CLIProxyAPI management endpoint (base URL + key), with a user-facing name.
struct CLIProxyConnection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var managementKey: String
    /// When true, sort this connection's accounts by weekly reset proximity and write priority.
    var preferNearRefreshAccounts: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        managementKey: String = "",
        preferNearRefreshAccounts: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.preferNearRefreshAccounts = preferNearRefreshAccounts
    }

    var isConfigured: Bool {
        !normalizedBaseURL.isEmpty && !normalizedManagementKey.isEmpty
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "CLIProxyAPI" : trimmed
    }

    var normalizedBaseURL: String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedManagementKey: String {
        managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One Sub2API endpoint (base URL + API key), with a user-facing name.
struct Sub2APIConnection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var isConfigured: Bool {
        !normalizedBaseURL.isEmpty && !normalizedAPIKey.isEmpty
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sub2API" : trimmed
    }

    var normalizedBaseURL: String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - App configuration

struct AppConfiguration: Codable, Equatable, Sendable {
    var cliProxyConnections: [CLIProxyConnection]
    var sub2APIConnections: [Sub2APIConnection]
    var refreshIntervalSeconds: Int
    /// CLIProxy connection IDs selected for desktop widget display. Empty = show none.
    var widgetCLIProxyConnectionIDs: [String]
    /// Sub2API connection IDs selected for desktop widget display. Empty = show none.
    var widgetSub2APIConnectionIDs: [String]

    init(
        cliProxyConnections: [CLIProxyConnection] = [],
        sub2APIConnections: [Sub2APIConnection] = [],
        refreshIntervalSeconds: Int = Self.defaultRefreshIntervalSeconds,
        widgetCLIProxyConnectionIDs: [String] = [],
        widgetSub2APIConnectionIDs: [String] = []
    ) {
        self.cliProxyConnections = cliProxyConnections
        self.sub2APIConnections = sub2APIConnections
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.widgetCLIProxyConnectionIDs = widgetCLIProxyConnectionIDs
        self.widgetSub2APIConnectionIDs = widgetSub2APIConnectionIDs
    }

    /// Convenience for tests and single-connection call sites.
    init(
        baseURL: String,
        managementKey: String,
        sub2APIBaseURL: String = "",
        sub2APIKey: String = "",
        refreshIntervalSeconds: Int,
        preferNearRefreshAccounts: Bool = false,
        cliProxyName: String = "默认",
        sub2APIName: String = "默认"
    ) {
        var cli: [CLIProxyConnection] = []
        if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cli = [
                CLIProxyConnection(
                    name: cliProxyName,
                    baseURL: baseURL,
                    managementKey: managementKey,
                    preferNearRefreshAccounts: preferNearRefreshAccounts
                )
            ]
        }

        var sub2: [Sub2APIConnection] = []
        if !sub2APIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sub2APIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sub2 = [
                Sub2APIConnection(
                    name: sub2APIName,
                    baseURL: sub2APIBaseURL,
                    apiKey: sub2APIKey
                )
            ]
        }

        self.init(
            cliProxyConnections: cli,
            sub2APIConnections: sub2,
            refreshIntervalSeconds: refreshIntervalSeconds,
            widgetCLIProxyConnectionIDs: cli.map(\.id),
            widgetSub2APIConnectionIDs: sub2.map(\.id)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case cliProxyConnections, sub2APIConnections, refreshIntervalSeconds
        case widgetCLIProxyConnectionIDs, widgetSub2APIConnectionIDs
        // Legacy single-connection keys (decode-only migration).
        case baseURL, managementKey, sub2APIBaseURL, sub2APIKey, preferNearRefreshAccounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)
            ?? Self.defaultRefreshIntervalSeconds

        if container.contains(.cliProxyConnections) || container.contains(.sub2APIConnections) {
            cliProxyConnections = try container.decodeIfPresent([CLIProxyConnection].self, forKey: .cliProxyConnections) ?? []
            sub2APIConnections = try container.decodeIfPresent([Sub2APIConnection].self, forKey: .sub2APIConnections) ?? []
            widgetCLIProxyConnectionIDs = try container.decodeIfPresent([String].self, forKey: .widgetCLIProxyConnectionIDs) ?? []
            widgetSub2APIConnectionIDs = try container.decodeIfPresent([String].self, forKey: .widgetSub2APIConnectionIDs) ?? []
        } else {
            // Migrate legacy single-connection config.
            let baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            let managementKey = try container.decodeIfPresent(String.self, forKey: .managementKey) ?? ""
            let prefer = try container.decodeIfPresent(Bool.self, forKey: .preferNearRefreshAccounts) ?? false
            let sub2Base = try container.decodeIfPresent(String.self, forKey: .sub2APIBaseURL) ?? ""
            let sub2Key = try container.decodeIfPresent(String.self, forKey: .sub2APIKey) ?? ""

            if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let connection = CLIProxyConnection(
                    name: "默认",
                    baseURL: baseURL,
                    managementKey: managementKey,
                    preferNearRefreshAccounts: prefer
                )
                cliProxyConnections = [connection]
                widgetCLIProxyConnectionIDs = [connection.id]
            } else {
                cliProxyConnections = []
                widgetCLIProxyConnectionIDs = []
            }

            if !sub2Base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !sub2Key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let connection = Sub2APIConnection(
                    name: "默认",
                    baseURL: sub2Base,
                    apiKey: sub2Key
                )
                sub2APIConnections = [connection]
                widgetSub2APIConnectionIDs = [connection.id]
            } else {
                sub2APIConnections = []
                widgetSub2APIConnectionIDs = []
            }
        }

        // Drop stale widget selection IDs that no longer exist.
        let cliIDs = Set(cliProxyConnections.map(\.id))
        let sub2IDs = Set(sub2APIConnections.map(\.id))
        widgetCLIProxyConnectionIDs = widgetCLIProxyConnectionIDs.filter { cliIDs.contains($0) }
        widgetSub2APIConnectionIDs = widgetSub2APIConnectionIDs.filter { sub2IDs.contains($0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cliProxyConnections, forKey: .cliProxyConnections)
        try container.encode(sub2APIConnections, forKey: .sub2APIConnections)
        try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(widgetCLIProxyConnectionIDs, forKey: .widgetCLIProxyConnectionIDs)
        try container.encode(widgetSub2APIConnectionIDs, forKey: .widgetSub2APIConnectionIDs)
    }

    static let defaultRefreshIntervalSeconds = 300
    static let minimumRefreshIntervalSeconds = 60

    static var empty: AppConfiguration {
        AppConfiguration()
    }

    /// At least one fully configured CLIProxyAPI connection.
    var isConfigured: Bool {
        cliProxyConnections.contains(where: \.isConfigured)
    }

    /// At least one fully configured Sub2API connection.
    var isSub2APIConfigured: Bool {
        sub2APIConnections.contains(where: \.isConfigured)
    }

    var hasAnyDataSource: Bool {
        isConfigured || isSub2APIConfigured
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(refreshIntervalSeconds, Self.minimumRefreshIntervalSeconds))
    }

    func cliProxyConnection(id: String) -> CLIProxyConnection? {
        cliProxyConnections.first { $0.id == id }
    }

    func sub2APIConnection(id: String) -> Sub2APIConnection? {
        sub2APIConnections.first { $0.id == id }
    }

    /// Configured CLIProxy connections selected for the widget, in connection list order.
    var widgetCLIProxyConnections: [CLIProxyConnection] {
        let selected = Set(widgetCLIProxyConnectionIDs)
        return cliProxyConnections.filter { selected.contains($0.id) && $0.isConfigured }
    }

    /// Configured Sub2API connections selected for the widget, in connection list order.
    var widgetSub2APIConnections: [Sub2APIConnection] {
        let selected = Set(widgetSub2APIConnectionIDs)
        return sub2APIConnections.filter { selected.contains($0.id) && $0.isConfigured }
    }

    var hasWidgetSelection: Bool {
        !widgetCLIProxyConnections.isEmpty || !widgetSub2APIConnections.isEmpty
    }

    /// Remove deleted connection IDs from widget selection lists.
    mutating func pruneWidgetSelection() {
        let cliIDs = Set(cliProxyConnections.map(\.id))
        let sub2IDs = Set(sub2APIConnections.map(\.id))
        widgetCLIProxyConnectionIDs = widgetCLIProxyConnectionIDs.filter { cliIDs.contains($0) }
        widgetSub2APIConnectionIDs = widgetSub2APIConnectionIDs.filter { sub2IDs.contains($0) }
    }
}

// MARK: - Persistence

enum AppConfigurationStore {
    static var configURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    static var applicationSupportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("aistat", isDirectory: true)
    }

    static func load() -> AppConfiguration {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: url)
            var config = try JSONDecoder().decode(AppConfiguration.self, from: data)
            if config.refreshIntervalSeconds <= 0 {
                config.refreshIntervalSeconds = AppConfiguration.defaultRefreshIntervalSeconds
            }
            config.pruneWidgetSelection()
            return config
        } catch {
            return .empty
        }
    }

    static func save(_ configuration: AppConfiguration) throws {
        let directory = applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var values = configuration
        if values.refreshIntervalSeconds <= 0 {
            values.refreshIntervalSeconds = AppConfiguration.defaultRefreshIntervalSeconds
        }
        values.pruneWidgetSelection()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        let tempURL = directory.appendingPathComponent("config.json.tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: configURL)
        }

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
