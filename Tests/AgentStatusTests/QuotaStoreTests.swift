import XCTest
@testable import AgentStatus

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
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.menuTitle, "Grok 20%")
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

    func testManualRefreshIsGatedToThreeMinutesUnlessForced() async {
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

        now = now.addingTimeInterval(179)
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 1)

        now = now.addingTimeInterval(2)
        await store.refresh(force: false)
        XCTAssertEqual(client.fetchAccountsCount, 2)

        await store.refresh(force: true)
        XCTAssertEqual(client.fetchAccountsCount, 3)
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
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.map(\.account.authIndex), ["expired", "near", "far", "missing"])
        XCTAssertEqual(client.priorityUpdates.last?.map(\.name), ["expired.json", "near.json", "far.json", "missing.json"])
        XCTAssertEqual(client.priorityUpdates.last?.map(\.priority), [4, 3, 2, 1])
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
            configuration: AppConfiguration(baseURL: "https://example.test", managementKey: "k", refreshIntervalSeconds: 300),
            includeMonthly: false,
            clientFactory: { _ in client },
            nowProvider: { now }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.accounts.map(\.account.authIndex), ["a", "b"])
        XCTAssertEqual(store.globalError?.contains("优先级同步失败"), true)
    }
}

private final class FakeClient: CLIProxyClientProtocol, @unchecked Sendable {
    var accounts: [AuthAccount]
    var weekly: [String: Result<WeeklyQuota, Error>]
    var accountsError: Error?
    var priorityError: Error?
    private(set) var fetchAccountsCount = 0
    private(set) var priorityUpdates: [[(name: String, priority: Int)]] = []

    init(accounts: [AuthAccount], weekly: [String: Result<WeeklyQuota, Error>]) {
        self.accounts = accounts
        self.weekly = weekly
    }

    func fetchXAIAccounts() async throws -> [AuthAccount] {
        fetchAccountsCount += 1
        if let accountsError { throw accountsError }
        return accounts
    }

    func fetchWeeklyQuota(authIndex: String) async throws -> WeeklyQuota {
        switch weekly[authIndex] {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw CLIProxyClientError.decoding("missing")
        }
    }

    func fetchMonthlyQuota(authIndex: String) async throws -> MonthlyQuota? {
        nil
    }

    func updateAuthPriorities(_ priorities: [(name: String, priority: Int)]) async throws {
        priorityUpdates.append(priorities)
        if let priorityError { throw priorityError }
    }
}
