import Foundation

struct AppConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var managementKey: String
    var refreshIntervalSeconds: Int

    static let defaultRefreshIntervalSeconds = 300
    static let minimumRefreshIntervalSeconds = 180

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

    var normalizedBaseURL: String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedManagementKey: String {
        managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return root.appendingPathComponent("agent-status", isDirectory: true)
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
