import Foundation

/// Shared snapshot store between the unsandboxed host app and the sandboxed widget.
///
/// WidgetKit extensions **must** enable App Sandbox or `pluginkit` will not register them.
/// App Groups need a provisioning profile; without one, chronod hangs on descriptor fetch.
///
/// Data path strategy:
/// - Host app (unsandboxed) writes into the widget's container Application Support directory
///   so the sandboxed extension can read it via the standard Application Support API.
/// - Also writes the host Application Support copy for debugging / non-extension tools.
public enum WidgetDataStore {
    public static let widgetBundleID = "app.aistat.widget"
    public static let snapshotFileName = "widget-snapshot.json"
    public static let applicationSupportFolder = "aistat"

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

    /// Standard Application Support path for the *current* process.
    /// Host → `~/Library/Application Support/aistat/`
    /// Sandboxed widget → `~/Library/Containers/app.aistat.widget/Data/Library/Application Support/aistat/`
    public static var processApplicationSupportSnapshotURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root
            .appendingPathComponent(applicationSupportFolder, isDirectory: true)
            .appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    /// Explicit widget-container path used by the host when publishing.
    public static var widgetContainerSnapshotURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportFolder, isDirectory: true)
            .appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    /// Host also keeps a copy next to config.json for inspection.
    public static var hostApplicationSupportSnapshotURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        // Prefer the real host Application Support, not a container (host is unsandboxed).
        return root
            .appendingPathComponent(applicationSupportFolder, isDirectory: true)
            .appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    public static func save(_ snapshot: WidgetSnapshot) throws {
        let data = try encoder.encode(snapshot)
        var lastError: Error?

        for url in [widgetContainerSnapshotURL, hostApplicationSupportSnapshotURL] {
            do {
                try writeAtomically(data, to: url)
            } catch {
                lastError = error
            }
        }

        // Widget container write is required for the sandboxed extension to see data.
        if !FileManager.default.fileExists(atPath: widgetContainerSnapshotURL.path), let lastError {
            throw lastError
        }
    }

    public static func load() -> WidgetSnapshot? {
        // Prefer the process-local Application Support (correct for sandboxed widget).
        let candidates = [
            processApplicationSupportSnapshotURL,
            widgetContainerSnapshotURL,
            hostApplicationSupportSnapshotURL
        ]
        var seen = Set<String>()
        for url in candidates {
            let path = url.path
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
