import Foundation
import Combine
import AppKit

@MainActor
final class QuotaStore: ObservableObject {
    static let minimumRefreshInterval: TimeInterval = TimeInterval(AppConfiguration.minimumRefreshIntervalSeconds)

    @Published private(set) var accounts: [AccountQuota] = []
    @Published private(set) var sub2APIUsage: Sub2APIUsage?
    @Published private(set) var sub2APIError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var nextRefreshAvailableAt: Date?
    @Published private(set) var globalError: String?
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var menuTitle: String = "额度 --"

    private var clientFactory: (AppConfiguration) -> any CLIProxyClientProtocol
    private var sub2APIClientFactory: (AppConfiguration) -> any Sub2APIClientProtocol
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var lastRefreshAttemptAt: Date?
    private var hasStarted = false
    private let includeMonthly: Bool
    private let nowProvider: () -> Date

    var canManualRefresh: Bool {
        guard !isRefreshing else { return false }
        guard let nextRefreshAvailableAt else { return true }
        return nowProvider() >= nextRefreshAvailableAt
    }

    init(
        configuration: AppConfiguration = AppConfigurationStore.load(),
        includeMonthly: Bool = true,
        clientFactory: @escaping (AppConfiguration) -> any CLIProxyClientProtocol = { CLIProxyClient(configuration: $0) },
        sub2APIClientFactory: @escaping (AppConfiguration) -> any Sub2APIClientProtocol = { Sub2APIClient(configuration: $0) },
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
        let hasCLIProxy = configuration.isConfigured
        let hasSub2API = configuration.isSub2APIConfigured

        guard hasCLIProxy || hasSub2API else {
            globalError = CLIProxyClientError.notConfigured.localizedDescription
            accounts = []
            sub2APIUsage = nil
            sub2APIError = nil
            updateMenuTitle()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let client = clientFactory(configuration)
        let sub2APIClient = sub2APIClientFactory(configuration)
        let shouldFetchMonthly = includeMonthly
        let now = nowProvider()

        async let sub2APIResult: Result<Sub2APIUsage, Error>? = {
            guard hasSub2API else { return nil }
            do {
                return .success(try await sub2APIClient.fetchUsage())
            } catch {
                return .failure(error)
            }
        }()

        if hasCLIProxy {
            do {
                let authAccounts = try await client.fetchAccounts()
                if authAccounts.isEmpty {
                    accounts = []
                    lastRefreshAt = now
                    updateMenuTitle()
                    globalError = nil
                } else {
                    var next: [AccountQuota] = authAccounts.map {
                        AccountQuota(account: $0, weekly: nil, monthly: nil, errorMessage: nil)
                    }

                    await withTaskGroup(of: (Int, WeeklyQuota?, MonthlyQuota?, String?).self) { group in
                        for (index, item) in next.enumerated() {
                            let account = item.account
                            group.addTask {
                                do {
                                    let weekly = try await client.fetchWeeklyQuota(for: account)
                                    var monthly: MonthlyQuota?
                                    if shouldFetchMonthly {
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

                    if configuration.preferNearRefreshAccounts {
                        let sorted = AccountQuotaSorter.sortByRefreshProximity(next, now: now)
                        accounts = sorted
                        lastRefreshAt = now
                        updateMenuTitle()

                        let priorities = AccountQuotaSorter.prioritiesByProximity(sorted, now: now)
                        do {
                            try await client.updateAuthPriorities(priorities)
                            globalError = nil
                        } catch {
                            // Keep sorted quota data even if priority write-back fails.
                            globalError = "额度已刷新，但优先级同步失败：\(error.localizedDescription)"
                        }
                    } else {
                        accounts = next
                        lastRefreshAt = now
                        updateMenuTitle()
                        globalError = nil
                    }
                }
            } catch {
                // Keep previous successful account rows if list fetch fails later.
                globalError = error.localizedDescription
                updateMenuTitle()
            }
        } else {
            accounts = []
            globalError = nil
            lastRefreshAt = now
            updateMenuTitle()
        }

        switch await sub2APIResult {
        case .success(let usage):
            sub2APIUsage = usage
            sub2APIError = nil
            lastRefreshAt = now
        case .failure(let error):
            sub2APIError = error.localizedDescription
        case .none:
            sub2APIUsage = nil
            sub2APIError = nil
        }
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        guard configuration.isConfigured || configuration.isSub2APIConfigured else {
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
