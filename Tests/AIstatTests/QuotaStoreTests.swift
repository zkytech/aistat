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

    func testManualRefreshIsGatedToOneMinuteUnlessForced() async {
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

        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)

        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)
        XCTAssertFalse(store.canManualRefresh)

        now = now.addingTimeInterval(59)
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)

        now = now.addingTimeInterval(1)
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 2)

        await store.refresh(force: true)
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
        XCTAssertEqual(store.sub2APIUsage?.availableBalance, 12.16)
        XCTAssertNil(store.sub2APIError)

        sub2.result = .failure(Sub2APIClientError.httpStatus(500, "balance down"))
        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].weekly?.usedPercent, 10)
        XCTAssertEqual(store.sub2APIError?.contains("balance down"), true)
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
        XCTAssertEqual(store.sub2APIUsage?.availableBalance, 0)
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