import XCTest
@testable import AIstat

@MainActor
final class QuotaStoreTests: XCTestCase {
    func testConcurrentRefreshIsolatesAccountFailuresAndPicksTightestRemaining() async {
        let accounts = [
            AuthAccount(provider: "xai", email: "tight@x.ai", name: "tight.json", authIndex: "a"),
            AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "b"),
            AuthAccount(provider: "xai", email: "fail@x.ai", name: "fail.json", authIndex: "c")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 80, periodStart: nil, periodEnd: nil, productUsage: [])),
                "b": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: nil, productUsage: [])),
                "c": .failure(CLIProxyClientError.httpStatus(500, "boom"))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                refreshIntervalSeconds: 300,
                preferNearRefreshAccounts: true
            ),
            includeMonthly: false,
            clientFactory: { _ in client }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.menuTitle, "额度 20%")
        XCTAssertNil(store.globalError)
        XCTAssertEqual(client.priorityUpdates.count, 1)
        XCTAssertEqual(client.priorityUpdates[0].map(\.name), ["fail.json", "ok.json", "tight.json"])
        // Missing periodEnd sorts last by display name; priorities still assigned highest-first after sort.
        XCTAssertEqual(client.priorityUpdates[0].map(\.priority), [3, 2, 1])
    }

    func testListFailureKeepsPreviousAccounts() async {
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client }
        )
        await store.refresh(force: true)
        XCTAssertEqual(store.accounts.count, 1)

        client.accountsError = CLIProxyClientError.httpStatus(503, "down")
        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].weekly?.usedPercent, 10)
        XCTAssertNotNil(store.globalError)
    }

    func testMenuOpenRefreshIsGatedButManualForceIsNot() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        // Opening the menu uses force: false (throttled).
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)
        XCTAssertTrue(store.canManualRefresh)

        // Re-open within the minimum interval is throttled.
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)

        now = now.addingTimeInterval(59)
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)

        // Manual refresh always uses force: true and is never rate-limited.
        await store.refresh(force: true)
        XCTAssertEqual(client.fetchAccountsCount, 2)
        XCTAssertTrue(store.canManualRefresh)

        // Menu-open throttle still applies after a manual refresh (timer resets).
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 2)

        now = now.addingTimeInterval(60)
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 3)
    }

    func testStartUsesThrottledRefreshAndIsIdempotent() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        store.start()
        await waitUntil(timeoutSeconds: 1) { client.fetchAccountsCount >= 1 }
        XCTAssertEqual(client.fetchAccountsCount, 1)

        store.start()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.fetchAccountsCount, 1)

        now = now.addingTimeInterval(60)
        store.start()
        await waitUntil(timeoutSeconds: 1) { client.fetchAccountsCount >= 2 }
        XCTAssertEqual(client.fetchAccountsCount, 2)
    }

    func testSortsByRefreshProximityAndSyncsDescendingPriorities() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let near = now.addingTimeInterval(3600)
        let far = now.addingTimeInterval(86_400)
        let expiredClose = now.addingTimeInterval(-600)

        let accounts = [
            AuthAccount(provider: "xai", email: "far@x.ai", name: "far.json", authIndex: "far"),
            AuthAccount(provider: "xai", email: "near@x.ai", name: "near.json", authIndex: "near"),
            AuthAccount(provider: "xai", email: "missing@x.ai", name: "missing.json", authIndex: "missing"),
            AuthAccount(provider: "xai", email: "expired@x.ai", name: "expired.json", authIndex: "expired")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "far": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: far, productUsage: [])),
                "near": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: near, productUsage: [])),
                "missing": .success(WeeklyQuota(usedPercent: 30, periodStart: nil, periodEnd: nil, productUsage: [])),
                "expired": .success(WeeklyQuota(usedPercent: 40, periodStart: nil, periodEnd: expiredClose, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                refreshIntervalSeconds: 300,
                preferNearRefreshAccounts: true
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.map(\.account.authIndex), ["expired", "near", "far", "missing"])
        XCTAssertEqual(client.priorityUpdates.last?.map(\.name), ["expired.json", "near.json", "far.json", "missing.json"])
        XCTAssertEqual(client.priorityUpdates.last?.map(\.priority), [4, 3, 2, 1])
    }

    func testPreferNearRefreshDisabledKeepsOrderAndSkipsPrioritySync() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let near = now.addingTimeInterval(3600)
        let far = now.addingTimeInterval(86_400)

        let accounts = [
            AuthAccount(provider: "xai", email: "far@x.ai", name: "far.json", authIndex: "far"),
            AuthAccount(provider: "xai", email: "near@x.ai", name: "near.json", authIndex: "near")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "far": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: far, productUsage: [])),
                "near": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: near, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                refreshIntervalSeconds: 300,
                preferNearRefreshAccounts: false
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.map(\.account.authIndex), ["far", "near"])
        XCTAssertTrue(client.priorityUpdates.isEmpty)
        XCTAssertNil(store.globalError)
    }

    func testPrioritySyncFailureDoesNotDropSortedAccounts() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let accounts = [
            AuthAccount(provider: "xai", email: "a@x.ai", name: "a.json", authIndex: "a"),
            AuthAccount(provider: "xai", email: "b@x.ai", name: "b.json", authIndex: "b")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: now.addingTimeInterval(100), productUsage: [])),
                "b": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: now.addingTimeInterval(200), productUsage: []))
            ]
        )
        client.priorityError = CLIProxyClientError.httpStatus(500, "priority failed")

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                refreshIntervalSeconds: 300,
                preferNearRefreshAccounts: true
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.map(\.account.authIndex), ["a", "b"])
        XCTAssertEqual(store.globalError?.contains("优先级同步失败"), true)
    }

    func testSub2APIBalanceSuccessAndFailureIsolation() async {
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: "按量",
                    unit: "USD",
                    balance: 12.16,
                    remaining: 12.16,
                    quota: nil,
                    subscription: nil
                )
            )
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                sub2APIBaseURL: "https://sub2api.example",
                sub2APIKey: "sub-key",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            sub2APIClientFactory: { _ in sub2 }
        )

        await store.refresh(force: true)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.sub2APIEntries.count, 1)
        XCTAssertEqual(store.sub2APIEntries[0].usage?.availableBalance, 12.16)
        XCTAssertNil(store.sub2APIEntries[0].error)

        sub2.result = .failure(Sub2APIClientError.httpStatus(500, "balance down"))
        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].weekly?.usedPercent, 10)
        XCTAssertEqual(store.sub2APIEntries[0].error?.contains("balance down"), true)
    }

    func testSub2APIOnlyConfigurationStillRefreshesBalance() async {
        let client = FakeClient(accounts: [], weekly: [:])
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: nil,
                    unit: "USD",
                    balance: 0,
                    remaining: 0,
                    quota: nil,
                    subscription: nil
                )
            )
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "",
                managementKey: "",
                sub2APIBaseURL: "https://sub2api.example",
                sub2APIKey: "sub-key",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            sub2APIClientFactory: { _ in sub2 }
        )

        await store.refresh(force: true)

        XCTAssertEqual(client.fetchAccountsCount, 0)
        XCTAssertEqual(store.accounts.count, 0)
        XCTAssertEqual(store.sub2APIEntries.count, 1)
        XCTAssertEqual(store.sub2APIEntries[0].usage?.availableBalance, 0)
        XCTAssertNil(store.globalError)
    }

    func testMissingWeeklyPercentFallsBackToMonthlyUsagePercent() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let accounts = [
            AuthAccount(provider: "xai", email: "zkytech_hg@icloud.com", name: "xai-zkytech_hg@icloud.com.json", authIndex: "hg")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "hg": .success(
                    WeeklyQuota(
                        usedPercent: nil,
                        periodStart: now.addingTimeInterval(-86_400),
                        periodEnd: now.addingTimeInterval(6 * 86_400),
                        productUsage: []
                    )
                )
            ],
            monthly: [
                "hg": .success(MonthlyQuota(limitCents: 15_000, usedCents: 5_336))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: true,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        guard let item = store.accounts.first else {
            return XCTFail("expected one account")
        }
        XCTAssertEqual(item.account.email, "zkytech_hg@icloud.com")
        XCTAssertEqual(item.weekly?.usedPercent ?? -1, 35.57333333333334, accuracy: 0.0001)
        XCTAssertEqual(item.weekly?.remainingPercent ?? -1, 64.42666666666666, accuracy: 0.0001)
        XCTAssertEqual(item.monthly?.limitCents, 15_000)
        XCTAssertEqual(item.monthly?.usedCents, 5_336)
        XCTAssertNil(item.errorMessage)
        XCTAssertEqual(store.menuTitle, "额度 64%")
    }

    func testExistingWeeklyPercentIsNotOverriddenByMonthly() async {
        let accounts = [
            AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "ok")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "ok": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: nil, productUsage: []))
            ],
            monthly: [
                "ok": .success(MonthlyQuota(limitCents: 10_000, usedCents: 9_000))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: true,
            clientFactory: { _ in client }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.first?.weekly?.usedPercent, 20)
        XCTAssertEqual(store.accounts.first?.weekly?.remainingPercent, 80)
        XCTAssertEqual(store.menuTitle, "额度 80%")
    }

    func testMultipleCLIProxyConnectionsGroupIndependentlyAndPriorityIsPerConnection() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let near = now.addingTimeInterval(3600)
        let far = now.addingTimeInterval(86_400)

        let home = CLIProxyConnection(
            id: "home",
            name: "家里",
            baseURL: "https://home.test",
            managementKey: "hk",
            preferNearRefreshAccounts: true
        )
        let office = CLIProxyConnection(
            id: "office",
            name: "公司",
            baseURL: "https://office.test",
            managementKey: "ok",
            preferNearRefreshAccounts: false
        )

        let homeClient = FakeClient(
            accounts: [
                AuthAccount(provider: "xai", email: "far@home", name: "far.json", authIndex: "far"),
                AuthAccount(provider: "xai", email: "near@home", name: "near.json", authIndex: "near")
            ],
            weekly: [
                "far": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: far, productUsage: [])),
                "near": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: near, productUsage: []))
            ]
        )
        let officeClient = FakeClient(
            accounts: [
                AuthAccount(provider: "xai", email: "a@office", name: "a.json", authIndex: "a"),
                AuthAccount(provider: "xai", email: "b@office", name: "b.json", authIndex: "b")
            ],
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 30, periodStart: nil, periodEnd: far, productUsage: [])),
                "b": .success(WeeklyQuota(usedPercent: 40, periodStart: nil, periodEnd: near, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                cliProxyConnections: [home, office],
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { connection in
                connection.id == home.id ? homeClient : officeClient
            },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accountGroups.map(\.connectionName), ["家里", "公司"])
        XCTAssertEqual(
            store.accountGroups[0].accounts.map(\.account.authIndex),
            ["near", "far"]
        )
        XCTAssertEqual(
            store.accountGroups[1].accounts.map(\.account.authIndex),
            ["a", "b"]
        )
        XCTAssertEqual(homeClient.priorityUpdates.count, 1)
        XCTAssertTrue(officeClient.priorityUpdates.isEmpty)
        XCTAssertEqual(store.accounts.map(\.connectionName), ["家里", "家里", "公司", "公司"])
        // IDs must be unique across hosts even with overlapping authIndex shapes.
        XCTAssertEqual(Set(store.accounts.map(\.id)).count, 4)
    }

    func testMultipleSub2APIEntriesCarryConnectionNames() async {
        let primary = Sub2APIConnection(id: "p", name: "主账户", baseURL: "https://a.example", apiKey: "k1")
        let backup = Sub2APIConnection(id: "b", name: "备用", baseURL: "https://b.example", apiKey: "k2")

        let clients: [String: FakeSub2APIClient] = [
            primary.id: FakeSub2APIClient(
                result: .success(
                    Sub2APIUsage(
                        mode: "unrestricted",
                        planName: "Pro",
                        unit: "USD",
                        balance: 10,
                        remaining: 10,
                        quota: nil,
                        subscription: nil
                    )
                )
            ),
            backup.id: FakeSub2APIClient(
                result: .success(
                    Sub2APIUsage(
                        mode: "unrestricted",
                        planName: nil,
                        unit: "USD",
                        balance: 1,
                        remaining: 1,
                        quota: nil,
                        subscription: nil
                    )
                )
            )
        ]

        let store = QuotaStore(
            configuration: AppConfiguration(
                sub2APIConnections: [primary, backup],
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in FakeClient(accounts: [], weekly: [:]) },
            sub2APIClientFactory: { connection in
                clients[connection.id]!
            }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.sub2APIEntries.map(\.connectionName), ["主账户", "备用"])
        XCTAssertEqual(store.sub2APIEntries.map { $0.usage?.availableBalance }, [10, 1])
    }

    func testLegacyConfigMigrationToNamedConnections() throws {
        let legacy = """
        {
          "baseURL": "https://legacy.test",
          "managementKey": "mk",
          "sub2APIBaseURL": "https://sub2.legacy",
          "sub2APIKey": "sk",
          "preferNearRefreshAccounts": true,
          "refreshIntervalSeconds": 120
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfiguration.self, from: legacy)
        XCTAssertEqual(config.cliProxyConnections.count, 1)
        XCTAssertEqual(config.cliProxyConnections[0].name, "默认")
        XCTAssertEqual(config.cliProxyConnections[0].baseURL, "https://legacy.test")
        XCTAssertTrue(config.cliProxyConnections[0].preferNearRefreshAccounts)
        XCTAssertEqual(config.sub2APIConnections.count, 1)
        XCTAssertEqual(config.sub2APIConnections[0].apiKey, "sk")
        XCTAssertTrue(config.deepSeekConnections.isEmpty)
        XCTAssertEqual(config.refreshIntervalSeconds, 120)
    }

    func testDeepSeekOnlyConfigurationRefreshesBalance() async {
        let client = FakeClient(accounts: [], weekly: [:])
        let ds = FakeDeepSeekClient(
            result: .success(
                DeepSeekBalance(
                    isAvailable: true,
                    currency: "USD",
                    totalBalance: 5.5
                )
            )
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "",
                managementKey: "",
                deepSeekAPIKey: "ds-key",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            deepSeekClientFactory: { _ in ds }
        )

        await store.refresh(force: true)

        XCTAssertEqual(client.fetchAccountsCount, 0)
        XCTAssertEqual(store.accounts.count, 0)
        XCTAssertEqual(store.deepSeekEntries.count, 1)
        XCTAssertEqual(store.deepSeekEntries[0].usage?.totalBalance, 5.5)
        XCTAssertEqual(store.balanceEntries.map(\.name), ["默认"])
        XCTAssertEqual(store.balanceEntries[0].balanceText, "$5.50")
        XCTAssertNil(store.globalError)
    }

    func testBalanceEntriesMergeSub2ThenDeepSeekInConfigOrder() async {
        let client = FakeClient(accounts: [], weekly: [:])
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: "Pro",
                    unit: "USD",
                    balance: 10,
                    remaining: 10,
                    quota: nil,
                    subscription: nil
                )
            )
        )
        let ds = FakeDeepSeekClient(
            result: .success(
                DeepSeekBalance(isAvailable: true, currency: "CNY", totalBalance: 30)
            )
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                sub2APIConnections: [Sub2APIConnection(id: "s1", name: "主账户", baseURL: "https://a.example", apiKey: "k1")],
                deepSeekConnections: [DeepSeekConnection(id: "d1", name: "DeepSeek", apiKey: "ds-key")],
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            sub2APIClientFactory: { _ in sub2 },
            deepSeekClientFactory: { _ in ds }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.balanceEntries.map(\.name), ["主账户", "DeepSeek"])
        XCTAssertEqual(store.balanceEntries.map(\.balanceText), ["$10.00", "¥30.00"])
    }

    func testDeepSeekFailureIsolatesFromOtherSources() async {
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )
        let ds = FakeDeepSeekClient(result: .failure(DeepSeekAPIClientError.httpStatus(500, "balance down")))

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                deepSeekAPIKey: "ds-key",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            deepSeekClientFactory: { _ in ds }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].weekly?.usedPercent, 10)
        XCTAssertEqual(store.deepSeekEntries[0].error?.contains("balance down"), true)
        XCTAssertNil(store.globalError, "partial balance failure must not surface as global error")
    }
}

private final class FakeClient: CLIProxyClientProtocol, @unchecked Sendable {
    var accounts: [AuthAccount]
    var weekly: [String: Result<WeeklyQuota, Error>]
    var monthly: [String: Result<MonthlyQuota?, Error>]
    var accountsError: Error?
    var priorityError: Error?
    private(set) var fetchAccountsCount = 0
    private(set) var priorityUpdates: [[(name: String, priority: Int)]] = []

    init(
        accounts: [AuthAccount],
        weekly: [String: Result<WeeklyQuota, Error>],
        monthly: [String: Result<MonthlyQuota?, Error>] = [:]
    ) {
        self.accounts = accounts
        self.weekly = weekly
        self.monthly = monthly
    }

    func fetchAccounts() async throws -> [AuthAccount] {
        fetchAccountsCount += 1
        if let accountsError { throw accountsError }
        return accounts
    }

    func fetchWeeklyQuota(for account: AuthAccount) async throws -> WeeklyQuota {
        switch weekly[account.authIndex] {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw CLIProxyClientError.decoding("missing")
        }
    }

    func fetchMonthlyQuota(for account: AuthAccount) async throws -> MonthlyQuota? {
        switch monthly[account.authIndex] {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            return nil
        }
    }

    func updateAuthPriorities(_ priorities: [(name: String, priority: Int)]) async throws {
        priorityUpdates.append(priorities)
        if let priorityError { throw priorityError }
    }
}

private final class FakeSub2APIClient: Sub2APIClientProtocol, @unchecked Sendable {
    var result: Result<Sub2APIUsage, Error>

    init(result: Result<Sub2APIUsage, Error>) {
        self.result = result
    }

    func fetchUsage() async throws -> Sub2APIUsage {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class FakeDeepSeekClient: DeepSeekClientProtocol, @unchecked Sendable {
    var result: Result<DeepSeekBalance, Error>

    init(result: Result<DeepSeekBalance, Error>) {
        self.result = result
    }

    func fetchBalance() async throws -> DeepSeekBalance {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
private func waitUntil(
    timeoutSeconds: TimeInterval = 1,
    pollNanoseconds: UInt64 = 5_000_000,
    condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
        await Task.yield()
    }
    XCTFail("condition not met within \(timeoutSeconds)s")
}
