import Foundation

struct AppConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var managementKey: String
    var sub2APIBaseURL: String
    var sub2APIKey: String
    var refreshIntervalSeconds: Int
    /// When true, sort CLIProxy accounts by nearness to weekly reset and write priority so
    /// CLIProxyAPI prefers accounts whose quota is about to refresh. Default off.
    var preferNearRefreshAccounts: Bool

    init(
        baseURL: String,
        managementKey: String,
        sub2APIBaseURL: String = "",
        sub2APIKey: String = "",
        refreshIntervalSeconds: Int,
        preferNearRefreshAccounts: Bool = false
    ) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.sub2APIBaseURL = sub2APIBaseURL
        self.sub2APIKey = sub2APIKey
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.preferNearRefreshAccounts = preferNearRefreshAccounts
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, managementKey, sub2APIBaseURL, sub2APIKey, refreshIntervalSeconds
        case preferNearRefreshAccounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        managementKey = try container.decodeIfPresent(String.self, forKey: .managementKey) ?? ""
        sub2APIBaseURL = try container.decodeIfPresent(String.self, forKey: .sub2APIBaseURL) ?? ""
        sub2APIKey = try container.decodeIfPresent(String.self, forKey: .sub2APIKey) ?? ""
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)
            ?? Self.defaultRefreshIntervalSeconds
        preferNearRefreshAccounts = try container.decodeIfPresent(Bool.self, forKey: .preferNearRefreshAccounts) ?? false
    }

    static let defaultRefreshIntervalSeconds = 300
    static let minimumRefreshIntervalSeconds = 60

    static var empty: AppConfiguration {
        AppConfiguration(
            baseURL: "",
            managementKey: "",
            refreshIntervalSeconds: defaultRefreshIntervalSeconds
        )
    }

    var isConfigured: Bool {
        !normalizedBaseURL.isEmpty && !normalizedManagementKey.isEmpty
    }

    var isSub2APIConfigured: Bool {
        !normalizedSub2APIBaseURL.isEmpty && !normalizedSub2APIKey.isEmpty
    }

    var normalizedBaseURL: String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedManagementKey: String {
        managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedSub2APIBaseURL: String {
        sub2APIBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedSub2APIKey: String {
        sub2APIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(refreshIntervalSeconds, Self.minimumRefreshIntervalSeconds))
    }
}

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
