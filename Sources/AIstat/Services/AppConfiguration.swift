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

    init(
        cliProxyConnections: [CLIProxyConnection] = [],
        sub2APIConnections: [Sub2APIConnection] = [],
        refreshIntervalSeconds: Int = Self.defaultRefreshIntervalSeconds
    ) {
        self.cliProxyConnections = cliProxyConnections
        self.sub2APIConnections = sub2APIConnections
        self.refreshIntervalSeconds = refreshIntervalSeconds
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
            refreshIntervalSeconds: refreshIntervalSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case cliProxyConnections, sub2APIConnections, refreshIntervalSeconds
        // Legacy keys (decode-only migration / ignored widget selection).
        case baseURL, managementKey, sub2APIBaseURL, sub2APIKey, preferNearRefreshAccounts
        case widgetCLIProxyConnectionIDs, widgetSub2APIConnectionIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)
            ?? Self.defaultRefreshIntervalSeconds

        if container.contains(.cliProxyConnections) || container.contains(.sub2APIConnections) {
            cliProxyConnections = try container.decodeIfPresent([CLIProxyConnection].self, forKey: .cliProxyConnections) ?? []
            sub2APIConnections = try container.decodeIfPresent([Sub2APIConnection].self, forKey: .sub2APIConnections) ?? []
            // widget* IDs intentionally ignored — selection is per-widget instance.
        } else {
            // Migrate legacy single-connection config.
            let baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            let managementKey = try container.decodeIfPresent(String.self, forKey: .managementKey) ?? ""
            let prefer = try container.decodeIfPresent(Bool.self, forKey: .preferNearRefreshAccounts) ?? false
            let sub2Base = try container.decodeIfPresent(String.self, forKey: .sub2APIBaseURL) ?? ""
            let sub2Key = try container.decodeIfPresent(String.self, forKey: .sub2APIKey) ?? ""

            if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliProxyConnections = [
                    CLIProxyConnection(
                        name: "默认",
                        baseURL: baseURL,
                        managementKey: managementKey,
                        preferNearRefreshAccounts: prefer
                    )
                ]
            } else {
                cliProxyConnections = []
            }

            if !sub2Base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !sub2Key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sub2APIConnections = [
                    Sub2APIConnection(
                        name: "默认",
                        baseURL: sub2Base,
                        apiKey: sub2Key
                    )
                ]
            } else {
                sub2APIConnections = []
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cliProxyConnections, forKey: .cliProxyConnections)
        try container.encode(sub2APIConnections, forKey: .sub2APIConnections)
        try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
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
