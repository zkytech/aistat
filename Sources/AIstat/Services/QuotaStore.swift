import Foundation
import Combine
import AppKit
import AIstatShared

@MainActor
final class QuotaStore: ObservableObject {
    static let minimumRefreshInterval: TimeInterval = TimeInterval(AppConfiguration.minimumRefreshIntervalSeconds)

    @Published private(set) var accountGroups: [CLIProxyAccountGroup] = []
    @Published private(set) var sub2APIEntries: [Sub2APIUsageEntry] = []
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

    private var clientFactory: (CLIProxyConnection) -> any CLIProxyClientProtocol
    private var sub2APIClientFactory: (Sub2APIConnection) -> any Sub2APIClientProtocol
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var lastRefreshAttemptAt: Date?
    private var hasStarted = false
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
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.includeMonthly = includeMonthly
        self.clientFactory = clientFactory
        self.sub2APIClientFactory = sub2APIClientFactory
        self.nowProvider = nowProvider
        updateMenuTitle()
    }

    func start() {
        if !hasStarted {
            hasStarted = true
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

        guard !cliConnections.isEmpty || !sub2Connections.isEmpty else {
            globalError = CLIProxyClientError.notConfigured.localizedDescription
            accountGroups = []
            sub2APIEntries = []
            updateMenuTitle()
            publishWidgetSnapshot(updatedAt: nowProvider())
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let shouldFetchMonthly = includeMonthly
        let now = nowProvider()
        var groupErrors: [String] = []

        // Snapshot previous groups so a list-fetch failure keeps last good rows for that host.
        let previousByID = Dictionary(uniqueKeysWithValues: accountGroups.map { ($0.connectionID, $0) })

        async let sub2Results: [Sub2APIUsageEntry] = fetchAllSub2API(connections: sub2Connections)

        if cliConnections.isEmpty {
            accountGroups = []
        } else {
            var nextGroups: [CLIProxyAccountGroup] = []

            await withTaskGroup(of: CLIProxyAccountGroup.self) { group in
                for connection in cliConnections {
                    let previous = previousByID[connection.id]
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
                for await result in group {
                    nextGroups.append(result)
                }
            }

            // Preserve configuration order (task group completes out of order).
            let order = Dictionary(uniqueKeysWithValues: cliConnections.enumerated().map { ($0.element.id, $0.offset) })
            nextGroups.sort { (order[$0.connectionID] ?? 0) < (order[$1.connectionID] ?? 0) }
            accountGroups = nextGroups
            groupErrors = nextGroups.compactMap { group in
                guard let error = group.error, !error.isEmpty else { return nil }
                return "\(group.connectionName)：\(error)"
            }
        }

        sub2APIEntries = await sub2Results
        lastRefreshAt = now

        if accountGroups.isEmpty && sub2APIEntries.allSatisfy({ $0.usage == nil }) {
            if let firstError = groupErrors.first
                ?? sub2APIEntries.compactMap(\.error).first {
                globalError = firstError
            } else {
                globalError = nil
            }
        } else if !groupErrors.isEmpty {
            // Partial success: surface priority / list errors without wiping data.
            globalError = groupErrors.joined(separator: "；")
        } else {
            globalError = nil
        }

        updateMenuTitle()
        publishWidgetSnapshot(updatedAt: lastRefreshAt ?? nowProvider())
    }

    private static func refreshCLIProxyGroup(
        connection: CLIProxyConnection,
        previous: CLIProxyAccountGroup?,
        client: any CLIProxyClientProtocol,
        includeMonthly: Bool,
        now: Date
    ) async -> CLIProxyAccountGroup {
        let connectionName = connection.displayName

        do {
            let authAccounts = try await client.fetchAccounts()
            if authAccounts.isEmpty {
                return CLIProxyAccountGroup(
                    connectionID: connection.id,
                    connectionName: connectionName,
                    accounts: [],
                    error: nil
                )
            }

            var next: [AccountQuota] = authAccounts.map {
                AccountQuota(
                    connectionID: connection.id,
                    connectionName: connectionName,
                    account: $0,
                    weekly: nil,
                    monthly: nil,
                    errorMessage: nil
                )
            }

            await withTaskGroup(of: (Int, WeeklyQuota?, MonthlyQuota?, String?).self) { group in
                for (index, item) in next.enumerated() {
                    let account = item.account
                    group.addTask {
                        do {
                            let weekly = try await client.fetchWeeklyQuota(for: account)
                            var monthly: MonthlyQuota?
                            if includeMonthly {
                                monthly = try? await client.fetchMonthlyQuota(for: account)
                            }
                            return (index, weekly.fillingMissingUsage(from: monthly), monthly, nil)
                        } catch {
                            return (index, nil, nil, error.localizedDescription)
                        }
                    }
                }

                for await (index, weekly, monthly, errorMessage) in group {
                    next[index].weekly = weekly
                    next[index].monthly = monthly
                    next[index].errorMessage = errorMessage
                }
            }

            if connection.preferNearRefreshAccounts {
                let sorted = AccountQuotaSorter.sortByRefreshProximity(next, now: now)
                let priorities = AccountQuotaSorter.prioritiesByProximity(sorted, now: now)
                do {
                    try await client.updateAuthPriorities(priorities)
                    return CLIProxyAccountGroup(
                        connectionID: connection.id,
                        connectionName: connectionName,
                        accounts: sorted,
                        error: nil
                    )
                } catch {
                    return CLIProxyAccountGroup(
                        connectionID: connection.id,
                        connectionName: connectionName,
                        accounts: sorted,
                        error: "额度已刷新，但优先级同步失败：\(error.localizedDescription)"
                    )
                }
            }

            return CLIProxyAccountGroup(
                connectionID: connection.id,
                connectionName: connectionName,
                accounts: next,
                error: nil
            )
        } catch {
            // Keep previous successful rows for this host if list fetch fails later.
            if let previous, !previous.accounts.isEmpty {
                return CLIProxyAccountGroup(
                    connectionID: connection.id,
                    connectionName: connectionName,
                    accounts: previous.accounts,
                    error: error.localizedDescription
                )
            }
            return CLIProxyAccountGroup(
                connectionID: connection.id,
                connectionName: connectionName,
                accounts: [],
                error: error.localizedDescription
            )
        }
    }

    private func fetchAllSub2API(connections: [Sub2APIConnection]) async -> [Sub2APIUsageEntry] {
        guard !connections.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, Sub2APIUsageEntry).self) { group in
            for (index, connection) in connections.enumerated() {
                let client = sub2APIClientFactory(connection)
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
                            )
                        )
                    } catch {
                        return (
                            index,
                            Sub2APIUsageEntry(
                                connectionID: connection.id,
                                connectionName: connection.displayName,
                                usage: nil,
                                error: error.localizedDescription
                            )
                        )
                    }
                }
            }

            var results: [(Int, Sub2APIUsageEntry)] = []
            for await item in group {
                results.append(item)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
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
            }

        WidgetBridge.publish(
            accounts: accounts,
            sub2Entries: sub2APIEntries,
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
