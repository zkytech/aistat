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
        // Failed refresh is ignored: keep last-good data and avoid failure UI.
        XCTAssertNil(store.globalError)
        XCTAssertNil(store.accountGroups.first?.error)
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
        let exhaustedNear = now.addingTimeInterval(300)

        let accounts = [
            AuthAccount(provider: "xai", email: "far@x.ai", name: "far.json", authIndex: "far"),
            AuthAccount(provider: "xai", email: "near@x.ai", name: "near.json", authIndex: "near"),
            AuthAccount(provider: "xai", email: "missing@x.ai", name: "missing.json", authIndex: "missing"),
            AuthAccount(provider: "xai", email: "expired@x.ai", name: "expired.json", authIndex: "expired"),
            AuthAccount(provider: "xai", email: "exhausted@x.ai", name: "exhausted.json", authIndex: "exhausted")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "far": .success(WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: far, productUsage: [])),
                "near": .success(WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: near, productUsage: [])),
                "missing": .success(WeeklyQuota(usedPercent: 30, periodStart: nil, periodEnd: nil, productUsage: [])),
                "expired": .success(WeeklyQuota(usedPercent: 40, periodStart: nil, periodEnd: expiredClose, productUsage: [])),
                // Closest periodEnd but weekly remaining 0% → last in menu list + lowest priority.
                "exhausted": .success(WeeklyQuota(usedPercent: 100, periodStart: nil, periodEnd: exhaustedNear, productUsage: []))
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

        // Menu bar UI order must match priority write-back order.
        XCTAssertEqual(store.accounts.map(\.account.authIndex), ["expired", "near", "far", "missing", "exhausted"])
        XCTAssertEqual(
            client.priorityUpdates.last?.map(\.name),
            ["expired.json", "near.json", "far.json", "missing.json", "exhausted.json"]
        )
        XCTAssertEqual(client.priorityUpdates.last?.map(\.priority), [5, 4, 3, 2, 1])
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
        // Priority write-back is best-effort; do not surface failure on the menu.
        XCTAssertNil(store.globalError)
        XCTAssertNil(store.accountGroups.first?.error)
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
        // Keep last good balance; do not show failure on the row.
        XCTAssertEqual(store.sub2APIEntries[0].usage?.availableBalance, 12.16)
        XCTAssertNil(store.sub2APIEntries[0].error)
        XCTAssertNil(store.globalError)
    }

    func testSub2APIDailyUsageFlowsIntoBalanceEntries() async {
        let client = FakeClient(accounts: [], weekly: [:])
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "subscription",
                    planName: "Pro",
                    unit: "USD",
                    balance: nil,
                    remaining: nil,
                    quota: nil,
                    subscription: Sub2APISubscription(
                        dailyUsageUSD: 1.23,
                        dailyLimitUSD: 5,
                        weeklyUsageUSD: 4.56,
                        weeklyLimitUSD: 20,
                        monthlyUsageUSD: 12.34,
                        monthlyLimitUSD: 100
                    )
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

        XCTAssertEqual(store.balanceEntries.count, 1)
        XCTAssertEqual(store.balanceEntries[0].balanceText, "$87.66")
        XCTAssertEqual(store.balanceEntries[0].dailyUsageText, "$1.23")
    }

    func testSub2APIWithoutDailyUsageKeepsDailyTextNil() async {
        let client = FakeClient(accounts: [], weekly: [:])
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: nil,
                    unit: "USD",
                    balance: 8,
                    remaining: 8,
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

        XCTAssertEqual(store.balanceEntries.count, 1)
        XCTAssertEqual(store.balanceEntries[0].balanceText, "$8.00")
        XCTAssertNil(store.balanceEntries[0].dailyUsageText)
    }

    func testSub2APITodayUsageZeroStillFlowsIntoDailyText() async {
        let client = FakeClient(accounts: [], weekly: [:])
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: "钱包余额",
                    unit: "USD",
                    balance: 10,
                    remaining: 10,
                    quota: nil,
                    subscription: nil,
                    usage: Sub2APIUsageStats(
                        today: Sub2APIUsageWindow(actualCost: 0, cost: 0),
                        total: Sub2APIUsageWindow(actualCost: 0, cost: 0)
                    )
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

        XCTAssertEqual(store.balanceEntries.count, 1)
        XCTAssertEqual(store.balanceEntries[0].balanceText, "$10.00")
        XCTAssertEqual(store.balanceEntries[0].dailyUsageText, "$0.00")
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
        // Failed DeepSeek request is ignored (no previous balance to keep).
        XCTAssertNil(store.deepSeekEntries[0].usage)
        XCTAssertNil(store.deepSeekEntries[0].error)
        XCTAssertNil(store.globalError, "partial balance failure must not surface as global error")
    }

    func testRefreshPersistsCacheAndStartHydratesUI() async {
        let cache = InMemoryQuotaCacheStore()
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 40, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: "Pro",
                    unit: "USD",
                    balance: 9.5,
                    remaining: 9.5,
                    quota: nil,
                    subscription: nil
                )
            )
        )
        let ds = FakeDeepSeekClient(
            result: .success(DeepSeekBalance(isAvailable: true, currency: "USD", totalBalance: 3))
        )

        let writer = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                sub2APIBaseURL: "https://sub2.example",
                sub2APIKey: "sk",
                deepSeekAPIKey: "ds",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            sub2APIClientFactory: { _ in sub2 },
            deepSeekClientFactory: { _ in ds },
            cacheStore: cache
        )

        await writer.refresh(force: true)

        XCTAssertEqual(cache.saveCount, 1)
        XCTAssertEqual(cache.snapshot?.accountGroups.first?.accounts.first?.weekly?.usedPercent, 40)
        XCTAssertEqual(cache.snapshot?.sub2APIEntries.first?.usage?.availableBalance, 9.5)
        XCTAssertEqual(cache.snapshot?.deepSeekEntries.first?.usage?.totalBalance, 3)
        XCTAssertNotNil(cache.snapshot?.lastRefreshAt)

        // Cold start: hydrate from disk before any network call.
        let silentClient = FakeClient(accounts: [], weekly: [:])
        silentClient.accountsError = CLIProxyClientError.httpStatus(503, "offline")
        let reader = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                sub2APIBaseURL: "https://sub2.example",
                sub2APIKey: "sk",
                deepSeekAPIKey: "ds",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in silentClient },
            sub2APIClientFactory: { _ in FakeSub2APIClient(result: .failure(Sub2APIClientError.httpStatus(500, "down"))) },
            deepSeekClientFactory: { _ in FakeDeepSeekClient(result: .failure(DeepSeekAPIClientError.httpStatus(500, "down"))) },
            cacheStore: cache
        )

        reader.start()
        // Hydration is synchronous in start(); UI should already show cached values.
        XCTAssertEqual(reader.accounts.first?.weekly?.usedPercent, 40)
        XCTAssertEqual(reader.menuTitle, "额度 60%")
        XCTAssertEqual(reader.sub2APIEntries.first?.usage?.availableBalance, 9.5)
        XCTAssertEqual(reader.deepSeekEntries.first?.usage?.totalBalance, 3)
        XCTAssertEqual(reader.balanceEntries.map(\.balanceText), ["$9.50", "$3.00"])
    }

    func testRefreshOverwritesCacheWithLatestAPIData() async {
        let cache = InMemoryQuotaCacheStore()
        cache.snapshot = QuotaCacheSnapshot(
            accountGroups: [
                CLIProxyAccountGroup(
                    connectionID: "c",
                    connectionName: "默认",
                    accounts: [
                        AccountQuota(
                            connectionID: "c",
                            connectionName: "默认",
                            account: AuthAccount(provider: "xai", email: "old@x.ai", name: "old.json", authIndex: "a"),
                            weekly: WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: nil, productUsage: [])
                        )
                    ],
                    error: nil
                )
            ],
            sub2APIEntries: [],
            deepSeekEntries: [],
            lastRefreshAt: Date(timeIntervalSince1970: 1),
            globalError: nil
        )

        let client = FakeClient(
            accounts: [AuthAccount(provider: "xai", email: "new@x.ai", name: "new.json", authIndex: "a")],
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 70, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client },
            cacheStore: cache
        )

        store.start()
        XCTAssertEqual(store.accounts.first?.weekly?.usedPercent, 10)
        XCTAssertEqual(store.menuTitle, "额度 90%")

        await waitUntil(timeoutSeconds: 1) { client.fetchAccountsCount >= 1 }
        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.first?.weekly?.usedPercent, 70)
        XCTAssertEqual(store.menuTitle, "额度 30%")
        XCTAssertEqual(cache.snapshot?.accountGroups.first?.accounts.first?.weekly?.usedPercent, 70)
        XCTAssertEqual(cache.snapshot?.accountGroups.first?.accounts.first?.account.email, "new@x.ai")
    }

    func testFailedRefreshDoesNotOverwriteCacheOrUI() async {
        let cache = InMemoryQuotaCacheStore()
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 25, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )
        let sub2 = FakeSub2APIClient(
            result: .success(
                Sub2APIUsage(
                    mode: "unrestricted",
                    planName: "Pro",
                    unit: "USD",
                    balance: 8,
                    remaining: 8,
                    quota: nil,
                    subscription: nil
                )
            )
        )
        let ds = FakeDeepSeekClient(
            result: .success(DeepSeekBalance(isAvailable: true, currency: "USD", totalBalance: 2))
        )

        let store = QuotaStore(
            configuration: AppConfiguration(
                baseURL: "https://example.test",
                managementKey: "k",
                sub2APIBaseURL: "https://sub2.example",
                sub2APIKey: "sk",
                deepSeekAPIKey: "ds",
                refreshIntervalSeconds: 300
            ),
            includeMonthly: false,
            clientFactory: { _ in client },
            sub2APIClientFactory: { _ in sub2 },
            deepSeekClientFactory: { _ in ds },
            cacheStore: cache
        )

        await store.refresh(force: true)
        XCTAssertEqual(cache.saveCount, 1)
        let cachedUsed = cache.snapshot?.accountGroups.first?.accounts.first?.weekly?.usedPercent
        XCTAssertEqual(cachedUsed, 25)
        XCTAssertEqual(store.menuTitle, "额度 75%")

        // Everything fails on the next refresh.
        client.accountsError = CLIProxyClientError.httpStatus(503, "down")
        sub2.result = .failure(Sub2APIClientError.httpStatus(500, "down"))
        ds.result = .failure(DeepSeekAPIClientError.httpStatus(500, "down"))
        await store.refresh(force: true)

        // Live UI keeps last-good values; disk cache is not rewritten with errors/empty.
        XCTAssertEqual(cache.saveCount, 1)
        XCTAssertEqual(cache.snapshot?.accountGroups.first?.accounts.first?.weekly?.usedPercent, 25)
        XCTAssertEqual(store.accounts.first?.weekly?.usedPercent, 25)
        XCTAssertEqual(store.sub2APIEntries.first?.usage?.availableBalance, 8)
        XCTAssertEqual(store.deepSeekEntries.first?.usage?.totalBalance, 2)
        XCTAssertEqual(store.menuTitle, "额度 75%")
        XCTAssertNil(store.globalError)
        XCTAssertNil(store.sub2APIEntries.first?.error)
        XCTAssertNil(store.deepSeekEntries.first?.error)
    }

    func testFirstFailedRefreshDoesNotWriteCache() async {
        let cache = InMemoryQuotaCacheStore()
        let client = FakeClient(accounts: [], weekly: [:])
        client.accountsError = CLIProxyClientError.httpStatus(503, "down")

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client },
            cacheStore: cache
        )

        await store.refresh(force: true)

        XCTAssertEqual(cache.saveCount, 0)
        XCTAssertNil(cache.snapshot)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.globalError)
    }

    func testPerAccountFetchFailureKeepsPreviousQuotaWithoutError() async {
        let accounts = [
            AuthAccount(provider: "xai", email: "ok@x.ai", name: "ok.json", authIndex: "a")
        ]
        let client = FakeClient(
            accounts: accounts,
            weekly: [
                "a": .success(WeeklyQuota(usedPercent: 15, periodStart: nil, periodEnd: nil, productUsage: []))
            ]
        )

        let store = QuotaStore(
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client }
        )

        await store.refresh(force: true)
        XCTAssertEqual(store.accounts.first?.weekly?.usedPercent, 15)

        client.weekly["a"] = .failure(CLIProxyClientError.httpStatus(500, "quota boom"))
        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.first?.weekly?.usedPercent, 15)
        XCTAssertNil(store.accounts.first?.errorMessage)
        XCTAssertEqual(store.menuTitle, "额度 85%")
        XCTAssertNil(store.globalError)
    }

    func testQuotaCacheRoundTripOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aistat-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("quota-cache.json")
        let periodEnd = Date(timeIntervalSince1970: 1_700_000_100)
        let original = QuotaCacheSnapshot(
            accountGroups: [
                CLIProxyAccountGroup(
                    connectionID: "home",
                    connectionName: "家里",
                    accounts: [
                        AccountQuota(
                            connectionID: "home",
                            connectionName: "家里",
                            account: AuthAccount(
                                provider: "xai",
                                email: "a@x.ai",
                                name: "a.json",
                                authIndex: "a",
                                unavailable: false,
                                disabled: false
                            ),
                            weekly: WeeklyQuota(
                                usedPercent: 25,
                                periodStart: Date(timeIntervalSince1970: 1_700_000_000),
                                periodEnd: periodEnd,
                                productUsage: [ProductUsage(product: "grok", usagePercent: 25)]
                            ),
                            monthly: MonthlyQuota(limitCents: 10_000, usedCents: 2_500)
                        )
                    ],
                    error: nil
                )
            ],
            sub2APIEntries: [
                Sub2APIUsageEntry(
                    connectionID: "s1",
                    connectionName: "主账户",
                    usage: Sub2APIUsage(
                        mode: "unrestricted",
                        planName: "Pro",
                        unit: "USD",
                        balance: 12.34,
                        remaining: 12.34,
                        quota: nil,
                        subscription: nil,
                        usage: Sub2APIUsageStats(
                            today: Sub2APIUsageWindow(actualCost: 1.1, cost: 1.2),
                            total: nil
                        )
                    ),
                    error: nil
                )
            ],
            deepSeekEntries: [
                DeepSeekUsageEntry(
                    connectionID: "d1",
                    connectionName: "DeepSeek",
                    usage: DeepSeekBalance(isAvailable: true, currency: "USD", totalBalance: 5.5),
                    error: nil
                )
            ],
            lastRefreshAt: Date(timeIntervalSince1970: 1_700_000_050),
            globalError: "partial"
        )

        try QuotaCacheStore.save(original, to: url)
        let loaded = QuotaCacheStore.load(from: url)

        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded?.deepSeekEntries.first?.usage?.totalBalance, 5.5)
        XCTAssertEqual(loaded?.sub2APIEntries.first?.usage?.dailyUsageText, "$1.10")
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

private final class InMemoryQuotaCacheStore: QuotaCacheStoreProtocol, @unchecked Sendable {
    var snapshot: QuotaCacheSnapshot?
    private(set) var saveCount = 0

    func load() -> QuotaCacheSnapshot? {
        snapshot
    }

    func save(_ snapshot: QuotaCacheSnapshot) throws {
        self.snapshot = snapshot
        saveCount += 1
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
