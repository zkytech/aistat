import Foundation
import Combine
import AppKit
import AIstatShared

@MainActor
final class QuotaStore: ObservableObject {
    static let minimumRefreshInterval: TimeInterval = TimeInterval(AppConfiguration.minimumRefreshIntervalSeconds)

    @Published private(set) var accountGroups: [CLIProxyAccountGroup] = []
    @Published private(set) var sub2APIEntries: [Sub2APIUsageEntry] = []
    @Published private(set) var deepSeekEntries: [DeepSeekUsageEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var nextRefreshAvailableAt: Date?
    @Published private(set) var globalError: String?
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var menuTitle: String = "额度 --"

    /// Flat subscription rows across all CLIProxy connections (menu title / hover lookup).
    var accounts: [AccountQuota] {
        accountGroups.flatMap(\.accounts)
    }

    /// Unified balance rows for the menu bar and widget snapshot: Sub2API then DeepSeek,
    /// each in configuration order.
    var balanceEntries: [BalanceEntry] {
        let sub2: [BalanceEntry] = sub2APIEntries.map { entry in
            let text = entry.usage.flatMap { usage -> String? in
                guard let balance = usage.availableBalance else { return nil }
                return BalanceFormatter.string(balance, unit: usage.unit)
            }
            return BalanceEntry(
                id: entry.connectionID,
                name: entry.connectionName,
                balanceText: text,
                planName: entry.usage?.planName,
                dailyUsageText: entry.usage?.dailyUsageText,
                error: entry.error
            )
        }
        let deepSeek: [BalanceEntry] = deepSeekEntries.map { entry in
            let text = entry.usage.flatMap { balance -> String? in
                guard let total = balance.totalBalance else { return nil }
                return BalanceFormatter.string(total, unit: balance.currency)
            }
            return BalanceEntry(
                id: entry.connectionID,
                name: entry.connectionName,
                balanceText: text,
                planName: nil,
                error: entry.error
            )
        }
        return sub2 + deepSeek
    }

    private var clientFactory: (CLIProxyConnection) -> any CLIProxyClientProtocol
    private var sub2APIClientFactory: (Sub2APIConnection) -> any Sub2APIClientProtocol
    private var deepSeekClientFactory: (DeepSeekConnection) -> any DeepSeekClientProtocol
    private var cacheStore: QuotaCacheStoreProtocol
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var lastRefreshAttemptAt: Date?
    private var hasStarted = false
    private var didHydrateFromCache = false
    private let includeMonthly: Bool
    private let nowProvider: () -> Date

    /// Manual refresh is never rate-limited; only blocked while a refresh is in flight.
    var canManualRefresh: Bool {
        !isRefreshing
    }

    init(
        configuration: AppConfiguration = AppConfigurationStore.load(),
        includeMonthly: Bool = true,
        clientFactory: @escaping (CLIProxyConnection) -> any CLIProxyClientProtocol = { CLIProxyClient(connection: $0) },
        sub2APIClientFactory: @escaping (Sub2APIConnection) -> any Sub2APIClientProtocol = { Sub2APIClient(connection: $0) },
        deepSeekClientFactory: @escaping (DeepSeekConnection) -> any DeepSeekClientProtocol = { DeepSeekClient(connection: $0) },
        cacheStore: any QuotaCacheStoreProtocol = NullQuotaCacheStore(),
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.includeMonthly = includeMonthly
        self.clientFactory = clientFactory
        self.sub2APIClientFactory = sub2APIClientFactory
        self.deepSeekClientFactory = deepSeekClientFactory
        self.cacheStore = cacheStore
        self.nowProvider = nowProvider
        updateMenuTitle()
    }

    func start() {
        if !hasStarted {
            hasStarted = true
            hydrateFromCacheIfNeeded()
            restartAutoRefresh()
        }
        Task { await refresh(force: false) }
    }

    func stop() {
        hasStarted = false
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func updateConfiguration(_ configuration: AppConfiguration) throws {
        try AppConfigurationStore.save(configuration)
        self.configuration = configuration
        restartAutoRefresh()
        Task { await refresh(force: true) }
    }

    func reloadConfigurationFromDisk() {
        configuration = AppConfigurationStore.load()
        restartAutoRefresh()
    }

    func refresh(force: Bool = false) async {
        let now = nowProvider()

        if !force {
            if let lastRefreshAttemptAt,
               now.timeIntervalSince(lastRefreshAttemptAt) < Self.minimumRefreshInterval {
                nextRefreshAvailableAt = lastRefreshAttemptAt.addingTimeInterval(Self.minimumRefreshInterval)
                return
            }
        }

        if let refreshTask {
            await refreshTask.value
            return
        }

        lastRefreshAttemptAt = now
        nextRefreshAvailableAt = now.addingTimeInterval(Self.minimumRefreshInterval)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        let cliConnections = configuration.cliProxyConnections.filter(\.isConfigured)
        let sub2Connections = configuration.sub2APIConnections.filter(\.isConfigured)
        let deepSeekConnections = configuration.deepSeekConnections.filter(\.isConfigured)

        guard !cliConnections.isEmpty || !sub2Connections.isEmpty || !deepSeekConnections.isEmpty else {
            // No data sources configured — clear live state and drop any stale cache.
            globalError = CLIProxyClientError.notConfigured.localizedDescription
            accountGroups = []
            sub2APIEntries = []
            deepSeekEntries = []
            lastRefreshAt = nil
            updateMenuTitle()
            // Empty config is intentional: overwrite cache so cold start does not resurrect old rows.
            persistCache(force: true)
            publishWidgetSnapshot(updatedAt: nowProvider())
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let shouldFetchMonthly = includeMonthly
        let now = nowProvider()

        // Snapshot previous rows so any failure keeps last good values instead of blanking UI.
        let previousGroupsByID = Dictionary(uniqueKeysWithValues: accountGroups.map { ($0.connectionID, $0) })
        let previousSub2ByID = Dictionary(uniqueKeysWithValues: sub2APIEntries.map { ($0.connectionID, $0) })
        let previousDeepSeekByID = Dictionary(uniqueKeysWithValues: deepSeekEntries.map { ($0.connectionID, $0) })

        async let sub2Fetch: (entries: [Sub2APIUsageEntry], anySuccess: Bool) = fetchAllSub2API(
            connections: sub2Connections,
            previousByID: previousSub2ByID
        )
        async let deepSeekFetch: (entries: [DeepSeekUsageEntry], anySuccess: Bool) = fetchAllDeepSeek(
            connections: deepSeekConnections,
            previousByID: previousDeepSeekByID
        )

        var nextGroups: [CLIProxyAccountGroup] = []
        var anyCLIProxySuccess = false

        if !cliConnections.isEmpty {
            await withTaskGroup(of: (CLIProxyAccountGroup, Bool).self) { group in
                for connection in cliConnections {
                    let previous = previousGroupsByID[connection.id]
                    group.addTask { [clientFactory, shouldFetchMonthly, now] in
                        await Self.refreshCLIProxyGroup(
                            connection: connection,
                            previous: previous,
                            client: clientFactory(connection),
                            includeMonthly: shouldFetchMonthly,
                            now: now
                        )
                    }
                }
                for await (result, succeeded) in group {
                    nextGroups.append(result)
                    if succeeded { anyCLIProxySuccess = true }
                }
            }

            // Preserve configuration order (task group completes out of order).
            let order = Dictionary(uniqueKeysWithValues: cliConnections.enumerated().map { ($0.element.id, $0.offset) })
            nextGroups.sort { (order[$0.connectionID] ?? 0) < (order[$1.connectionID] ?? 0) }
        }

        let sub2 = await sub2Fetch
        let deepSeek = await deepSeekFetch

        // Fresh success only: fallback-to-previous does not count.
        let anyFreshSuccess = anyCLIProxySuccess || sub2.anySuccess || deepSeek.anySuccess

        // Complete failure: ignore this request — leave live UI and disk cache untouched.
        if !anyFreshSuccess {
            updateMenuTitle()
            return
        }

        accountGroups = nextGroups
        sub2APIEntries = sub2.entries
        deepSeekEntries = deepSeek.entries
        lastRefreshAt = now
        // Prefer showing last-good data over failure banners.
        globalError = nil

        updateMenuTitle()
        persistCache()
        publishWidgetSnapshot(updatedAt: lastRefreshAt ?? nowProvider())
    }

    /// Loads last known API data so the menu bar / panel show content immediately.
    private func hydrateFromCacheIfNeeded() {
        guard !didHydrateFromCache else { return }
        didHydrateFromCache = true

        guard let snapshot = cacheStore.load(), snapshot.hasData else { return }

        accountGroups = snapshot.accountGroups
        sub2APIEntries = snapshot.sub2APIEntries
        deepSeekEntries = snapshot.deepSeekEntries
        lastRefreshAt = snapshot.lastRefreshAt
        // Never restore a cached error banner — only display-ready rows.
        globalError = nil
        updateMenuTitle()

        // Push cached data into the widget before the first network refresh finishes.
        publishWidgetSnapshot(updatedAt: snapshot.lastRefreshAt ?? nowProvider())
    }

    /// Writes a privacy-safe display snapshot. Failed refreshes must not call this
    /// (except `force` when the user clears all data sources).
    private func persistCache(force: Bool = false) {
        let snapshot = QuotaCacheSnapshot(
            accountGroups: Self.cacheSanitizedGroups(accountGroups),
            sub2APIEntries: Self.cacheSanitizedSub2(sub2APIEntries),
            deepSeekEntries: Self.cacheSanitizedDeepSeek(deepSeekEntries),
            lastRefreshAt: lastRefreshAt,
            globalError: nil
        )
        guard force || snapshot.hasData else { return }
        try? cacheStore.save(snapshot)
    }

    /// Strip per-row error markers so a later hydrate never resurrects failure UI.
    private static func cacheSanitizedGroups(_ groups: [CLIProxyAccountGroup]) -> [CLIProxyAccountGroup] {
        groups.map { group in
            CLIProxyAccountGroup(
                connectionID: group.connectionID,
                connectionName: group.connectionName,
                accounts: group.accounts.map { item in
                    var copy = item
                    // Keep last known weekly/monthly; drop transient error text.
                    if copy.weekly != nil || copy.monthly != nil {
                        copy.errorMessage = nil
                    }
                    return copy
                },
                error: nil
            )
        }
    }

    private static func cacheSanitizedSub2(_ entries: [Sub2APIUsageEntry]) -> [Sub2APIUsageEntry] {
        entries.compactMap { entry in
            guard entry.usage != nil else { return nil }
            return Sub2APIUsageEntry(
                connectionID: entry.connectionID,
                connectionName: entry.connectionName,
                usage: entry.usage,
                error: nil
            )
        }
    }

    private static func cacheSanitizedDeepSeek(_ entries: [DeepSeekUsageEntry]) -> [DeepSeekUsageEntry] {
        entries.compactMap { entry in
            guard entry.usage != nil else { return nil }
            return DeepSeekUsageEntry(
                connectionID: entry.connectionID,
                connectionName: entry.connectionName,
                usage: entry.usage,
                error: nil
            )
        }
    }

    /// Returns the group plus whether this host produced a fresh successful list fetch.
    private static func refreshCLIProxyGroup(
        connection: CLIProxyConnection,
        previous: CLIProxyAccountGroup?,
        client: any CLIProxyClientProtocol,
        includeMonthly: Bool,
        now: Date
    ) async -> (CLIProxyAccountGroup, Bool) {
        let connectionName = connection.displayName
        let previousByAuth = Dictionary(
            uniqueKeysWithValues: (previous?.accounts ?? []).map { ($0.account.authIndex, $0) }
        )

        do {
            let authAccounts = try await client.fetchAccounts()
            if authAccounts.isEmpty {
                return (
                    CLIProxyAccountGroup(
                        connectionID: connection.id,
                        connectionName: connectionName,
                        accounts: [],
                        error: nil
                    ),
                    true
                )
            }

            var next: [AccountQuota] = authAccounts.map { account in
                let prior = previousByAuth[account.authIndex]
                return AccountQuota(
                    connectionID: connection.id,
                    connectionName: connectionName,
                    account: account,
                    // Seed with last-known quotas so a per-account failure keeps numbers on screen.
                    weekly: prior?.weekly,
                    monthly: prior?.monthly,
                    errorMessage: nil
                )
            }

            await withTaskGroup(of: (Int, WeeklyQuota?, MonthlyQuota?, Bool).self) { group in
                for (index, item) in next.enumerated() {
                    let account = item.account
                    group.addTask {
                        do {
                            let weekly = try await client.fetchWeeklyQuota(for: account)
                            var monthly: MonthlyQuota?
                            if includeMonthly {
                                monthly = try? await client.fetchMonthlyQuota(for: account)
                            }
                            return (index, weekly.fillingMissingUsage(from: monthly), monthly, true)
                        } catch {
                            // Signal failure; caller keeps seeded previous weekly/monthly.
                            return (index, nil, nil, false)
                        }
                    }
                }

                for await (index, weekly, monthly, succeeded) in group {
                    if succeeded {
                        next[index].weekly = weekly
                        // Monthly may be nil when includeMonthly is false or monthly call failed softly.
                        if includeMonthly {
                            next[index].monthly = monthly ?? next[index].monthly
                        }
                        next[index].errorMessage = nil
                    }
                    // On failure: leave seeded previous values, no errorMessage (avoid failure UI).
                }
            }

            if connection.preferNearRefreshAccounts {
                let sorted = AccountQuotaSorter.sortByRefreshProximity(next, now: now)
                let priorities = AccountQuotaSorter.prioritiesByProximity(sorted, now: now)
                // Priority write-back is best-effort; never blank quota rows on sync failure.
                try? await client.updateAuthPriorities(priorities)
                return (
                    CLIProxyAccountGroup(
                        connectionID: connection.id,
                        connectionName: connectionName,
                        accounts: sorted,
                        error: nil
                    ),
                    true
                )
            }

            return (
                CLIProxyAccountGroup(
                    connectionID: connection.id,
                    connectionName: connectionName,
                    accounts: next,
                    error: nil
                ),
                true
            )
        } catch {
            // Keep previous successful rows for this host if list fetch fails later.
            if let previous, !previous.accounts.isEmpty {
                return (
                    CLIProxyAccountGroup(
                        connectionID: connection.id,
                        connectionName: connectionName,
                        accounts: previous.accounts.map { item in
                            var copy = item
                            copy.errorMessage = nil
                            return copy
                        },
                        error: nil
                    ),
                    false
                )
            }
            return (
                CLIProxyAccountGroup(
                    connectionID: connection.id,
                    connectionName: connectionName,
                    accounts: [],
                    error: nil
                ),
                false
            )
        }
    }

    private func fetchAllSub2API(
        connections: [Sub2APIConnection],
        previousByID: [String: Sub2APIUsageEntry]
    ) async -> (entries: [Sub2APIUsageEntry], anySuccess: Bool) {
        guard !connections.isEmpty else { return ([], false) }

        return await withTaskGroup(of: (Int, Sub2APIUsageEntry, Bool).self) { group in
            for (index, connection) in connections.enumerated() {
                let client = sub2APIClientFactory(connection)
                let previous = previousByID[connection.id]
                group.addTask {
                    do {
                        let usage = try await client.fetchUsage()
                        return (
                            index,
                            Sub2APIUsageEntry(
                                connectionID: connection.id,
                                connectionName: connection.displayName,
                                usage: usage,
                                error: nil
                            ),
                            true
                        )
                    } catch {
                        // Ignore failed request: keep last good balance when available.
                        if let previous, previous.usage != nil {
                            return (
                                index,
                                Sub2APIUsageEntry(
                                    connectionID: connection.id,
                                    connectionName: connection.displayName,
                                    usage: previous.usage,
                                    error: nil
                                ),
                                false
                            )
                        }
                        return (
                            index,
                            Sub2APIUsageEntry(
                                connectionID: connection.id,
                                connectionName: connection.displayName,
                                usage: nil,
                                error: nil
                            ),
                            false
                        )
                    }
                }
            }

            var results: [(Int, Sub2APIUsageEntry, Bool)] = []
            for await item in group {
                results.append(item)
            }
            let ordered = results.sorted { $0.0 < $1.0 }
            return (ordered.map(\.1), ordered.contains(where: \.2))
        }
    }

    private func fetchAllDeepSeek(
        connections: [DeepSeekConnection],
        previousByID: [String: DeepSeekUsageEntry]
    ) async -> (entries: [DeepSeekUsageEntry], anySuccess: Bool) {
        guard !connections.isEmpty else { return ([], false) }

        return await withTaskGroup(of: (Int, DeepSeekUsageEntry, Bool).self) { group in
            for (index, connection) in connections.enumerated() {
                let client = deepSeekClientFactory(connection)
                let previous = previousByID[connection.id]
                group.addTask {
                    do {
                        let balance = try await client.fetchBalance()
                        // Soft empty when unavailable; still a successful API response.
                        return (
                            index,
                            DeepSeekUsageEntry(
                                connectionID: connection.id,
                                connectionName: connection.displayName,
                                usage: balance,
                                error: nil
                            ),
                            true
                        )
                    } catch {
                        // Ignore failed request: keep last good balance when available.
                        if let previous, previous.usage != nil {
                            return (
                                index,
                                DeepSeekUsageEntry(
                                    connectionID: connection.id,
                                    connectionName: connection.displayName,
                                    usage: previous.usage,
                                    error: nil
                                ),
                                false
                            )
                        }
                        return (
                            index,
                            DeepSeekUsageEntry(
                                connectionID: connection.id,
                                connectionName: connection.displayName,
                                usage: nil,
                                error: nil
                            ),
                            false
                        )
                    }
                }
            }

            var results: [(Int, DeepSeekUsageEntry, Bool)] = []
            for await item in group {
                results.append(item)
            }
            let ordered = results.sorted { $0.0 < $1.0 }
            return (ordered.map(\.1), ordered.contains(where: \.2))
        }
    }

    private func publishWidgetSnapshot(updatedAt: Date) {
        // Full snapshot for all connections; each widget instance filters via App Intent config.
        let sources: [WidgetSourceInfo] =
            configuration.cliProxyConnections.filter(\.isConfigured).map {
                WidgetSourceInfo(
                    id: $0.id,
                    name: $0.displayName,
                    kind: WidgetSourceKind.cliproxy.rawValue
                )
            } + configuration.sub2APIConnections.filter(\.isConfigured).map {
                WidgetSourceInfo(
                    id: $0.id,
                    name: $0.displayName,
                    kind: WidgetSourceKind.sub2api.rawValue
                )
            } + configuration.deepSeekConnections.filter(\.isConfigured).map {
                WidgetSourceInfo(
                    id: $0.id,
                    name: $0.displayName,
                    kind: WidgetSourceKind.deepseek.rawValue
                )
            }

        WidgetBridge.publish(
            accounts: accounts,
            balanceEntries: balanceEntries,
            sources: sources,
            globalError: globalError,
            isConfigured: configuration.hasAnyDataSource,
            updatedAt: updatedAt
        )
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        guard configuration.hasAnyDataSource else {
            autoRefreshTask = nil
            return
        }

        let interval = max(configuration.refreshInterval, Self.minimumRefreshInterval)
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh(force: true)
            }
        }
    }

    private func updateMenuTitle() {
        let remainingCandidates = accounts.compactMap { item -> Double? in
            if item.account.disabled || item.account.unavailable {
                return nil
            }
            return item.weekly?.remainingPercent
        }

        if let lowestRemaining = remainingCandidates.min() {
            menuTitle = String(format: "额度 %.0f%%", lowestRemaining)
        } else if accounts.contains(where: { $0.errorMessage != nil }) {
            menuTitle = "额度 !!"
        } else {
            menuTitle = "额度 --"
        }
    }
}
