import AppIntents
import AIstatShared
import WidgetKit

// MARK: - Entities (from privacy-safe snapshot catalog)

struct CLIProxySourceEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "CLIProxyAPI 账号")
    static var defaultQuery = CLIProxySourceQuery()

    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CLIProxySourceQuery: EntityQuery {
    func entities(for identifiers: [CLIProxySourceEntity.ID]) async throws -> [CLIProxySourceEntity] {
        let wanted = Set(identifiers)
        return Self.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CLIProxySourceEntity] {
        Self.all()
    }

    static func all() -> [CLIProxySourceEntity] {
        let sources = (WidgetDataStore.load() ?? .empty).sources
        return sources
            .filter { $0.sourceKind == .cliproxy }
            .map { CLIProxySourceEntity(id: $0.id, name: $0.displayName) }
    }
}

struct Sub2SourceEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "余额账号")
    static var defaultQuery = Sub2SourceQuery()

    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct Sub2SourceQuery: EntityQuery {
    func entities(for identifiers: [Sub2SourceEntity.ID]) async throws -> [Sub2SourceEntity] {
        let wanted = Set(identifiers)
        return Self.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [Sub2SourceEntity] {
        Self.all()
    }

    static func all() -> [Sub2SourceEntity] {
        let sources = (WidgetDataStore.load() ?? .empty).sources
        // Sub2API 与 DeepSeek 共享同一个余额选择列表。
        return sources
            .filter { $0.sourceKind == .sub2api || $0.sourceKind == .deepseek }
            .map { Sub2SourceEntity(id: $0.id, name: $0.displayName) }
    }
}

// MARK: - Per-instance widget configuration

struct AIstatWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "展示账号"
    static var description = IntentDescription("为此小组件实例选择要展示的 CLIProxyAPI 账号与余额账号（Sub2API / DeepSeek 单选）。未选择时小组件为空。")

    // Non-optional array (multi-select CLIProxy accounts) — Optional<[AppEntity]> confuses
    // appintentsmetadataprocessor ("Unable to determine value type").
    @Parameter(title: "CLIProxyAPI 账号", default: [])
    var cliProxyAccounts: [CLIProxySourceEntity]

    // Single-select balance source shared by Sub2API and DeepSeek.
    @Parameter(title: "余额账号")
    var balanceSource: Sub2SourceEntity?

    init() {
        self.cliProxyAccounts = []
        self.balanceSource = nil
    }

    init(cliProxyAccounts: [CLIProxySourceEntity], balanceSource: Sub2SourceEntity?) {
        self.cliProxyAccounts = cliProxyAccounts
        self.balanceSource = balanceSource
    }

    var selectedCLIProxyIDs: Set<String> {
        Set(cliProxyAccounts.map(\.id))
    }

    var selectedBalanceSourceID: String? {
        balanceSource?.id
    }
}

// MARK: - Timeline

struct QuotaIntentTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaWidgetEntry {
        .placeholder
    }

    func snapshot(
        for configuration: AIstatWidgetConfigurationIntent,
        in context: Context
    ) async -> QuotaWidgetEntry {
        makeEntry(configuration: configuration)
    }

    func timeline(
        for configuration: AIstatWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<QuotaWidgetEntry> {
        let entry = makeEntry(configuration: configuration)
        // Widgets are system-throttled; 15 min keeps data reasonably fresh
        // while main app also calls reloadAllTimelines() after each refresh.
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(configuration: AIstatWidgetConfigurationIntent) -> QuotaWidgetEntry {
        let full = WidgetDataStore.load() ?? .empty
        let filtered = full.filtered(
            cliProxySourceIDs: configuration.selectedCLIProxyIDs,
            balanceSourceID: configuration.selectedBalanceSourceID
        )
        return QuotaWidgetEntry(date: Date(), snapshot: filtered)
    }
}
