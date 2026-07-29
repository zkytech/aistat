import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var accounts: [AccountQuota] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var globalError: String?
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var menuTitle: String = "Grok --"

    private var clientFactory: (AppConfiguration) -> any CLIProxyClientProtocol
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var lastManualRefreshAt: Date?
    private let manualDebounceInterval: TimeInterval = 1.5
    private let includeMonthly: Bool

    init(
        configuration: AppConfiguration = AppConfigurationStore.load(),
        includeMonthly: Bool = true,
        clientFactory: @escaping (AppConfiguration) -> any CLIProxyClientProtocol = { CLIProxyClient(configuration: $0) }
    ) {
        self.configuration = configuration
        self.includeMonthly = includeMonthly
        self.clientFactory = clientFactory
        updateMenuTitle()
    }

    func start() {
        restartAutoRefresh()
        Task { await refresh(force: true) }
    }

    func stop() {
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
        if !force, let lastManualRefreshAt, Date().timeIntervalSince(lastManualRefreshAt) < manualDebounceInterval {
            return
        }
        lastManualRefreshAt = Date()

        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { [weak self] in
            await self?.performRefresh()
            return
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard configuration.isConfigured else {
            globalError = CLIProxyClientError.notConfigured.localizedDescription
            accounts = []
            updateMenuTitle()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let client = clientFactory(configuration)
        let shouldFetchMonthly = includeMonthly

        do {
            let authAccounts = try await client.fetchXAIAccounts()
            if authAccounts.isEmpty {
                accounts = []
                globalError = nil
                lastRefreshAt = Date()
                updateMenuTitle()
                return
            }

            var next: [AccountQuota] = authAccounts.map {
                AccountQuota(account: $0, weekly: nil, monthly: nil, errorMessage: nil)
            }

            await withTaskGroup(of: (Int, WeeklyQuota?, MonthlyQuota?, String?).self) { group in
                for (index, item) in next.enumerated() {
                    let authIndex = item.account.authIndex
                    group.addTask {
                        do {
                            let weekly = try await client.fetchWeeklyQuota(authIndex: authIndex)
                            var monthly: MonthlyQuota?
                            if shouldFetchMonthly {
                                monthly = try? await client.fetchMonthlyQuota(authIndex: authIndex)
                            }
                            return (index, weekly, monthly, nil)
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

            accounts = next
            globalError = nil
            lastRefreshAt = Date()
            updateMenuTitle()
        } catch {
            // Keep previous successful account rows if list fetch fails later.
            globalError = error.localizedDescription
            updateMenuTitle()
        }
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        guard configuration.isConfigured else {
            autoRefreshTask = nil
            return
        }

        let interval = configuration.refreshInterval
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
            menuTitle = String(format: "Grok %.0f%%", lowestRemaining)
        } else if accounts.contains(where: { $0.errorMessage != nil }) {
            menuTitle = "Grok !!"
        } else {
            menuTitle = "Grok --"
        }
    }
}
