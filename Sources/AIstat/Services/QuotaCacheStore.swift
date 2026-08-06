import Foundation

/// Disk snapshot of the last successful API refresh for offline / cold-start UI.
struct QuotaCacheSnapshot: Codable, Equatable, Sendable {
    var accountGroups: [CLIProxyAccountGroup]
    var sub2APIEntries: [Sub2APIUsageEntry]
    var deepSeekEntries: [DeepSeekUsageEntry]
    var lastRefreshAt: Date?
    var globalError: String?

    static var empty: QuotaCacheSnapshot {
        QuotaCacheSnapshot(
            accountGroups: [],
            sub2APIEntries: [],
            deepSeekEntries: [],
            lastRefreshAt: nil,
            globalError: nil
        )
    }

    var hasData: Bool {
        !accountGroups.isEmpty || !sub2APIEntries.isEmpty || !deepSeekEntries.isEmpty
    }
}

/// Test seam for disk cache I/O.
protocol QuotaCacheStoreProtocol: Sendable {
    func load() -> QuotaCacheSnapshot?
    func save(_ snapshot: QuotaCacheSnapshot) throws
}

/// Persists menu-bar quota data under Application Support (next to config.json).
/// No secrets — only display-ready usage / balance rows.
enum QuotaCacheStore {
    static let fileName = "quota-cache.json"

    static var cacheURL: URL {
        AppConfigurationStore.applicationSupportDirectory
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func load(from url: URL = cacheURL) -> QuotaCacheSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(QuotaCacheSnapshot.self, from: data)
    }

    static func save(_ snapshot: QuotaCacheSnapshot, to url: URL = cacheURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try encoder.encode(snapshot)
        let tempURL = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear(at url: URL = cacheURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct DefaultQuotaCacheStore: QuotaCacheStoreProtocol {
    func load() -> QuotaCacheSnapshot? {
        QuotaCacheStore.load()
    }

    func save(_ snapshot: QuotaCacheSnapshot) throws {
        try QuotaCacheStore.save(snapshot)
    }
}

/// No-op store for unit tests (avoids touching Application Support).
struct NullQuotaCacheStore: QuotaCacheStoreProtocol {
    func load() -> QuotaCacheSnapshot? { nil }
    func save(_ snapshot: QuotaCacheSnapshot) throws {}
}
