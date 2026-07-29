import XCTest
@testable import AgentStatus

@MainActor
final class QuotaStoreTests: XCTestCase {
    func testConcurrentRefreshIsolatesAccountFailuresAndPicksTightestRemaining() async {
        let accounts = [
            AuthAccount(provider: "xai", email: "tight@x.ai", authIndex: "a"),
            AuthAccount(provider: "xai", email: "ok@x.ai", authIndex: "b"),
            AuthAccount(provider: "xai", email: "fail@x.ai", authIndex: "c")
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
        XCTAssertEqual(store.accounts[0].weekly?.usedPercent, 80)
        XCTAssertEqual(store.accounts[1].weekly?.usedPercent, 20)
        XCTAssertNotNil(store.accounts[2].errorMessage)
        XCTAssertEqual(store.menuTitle, "Grok 20%")
        XCTAssertNil(store.globalError)
    }

    func testListFailureKeepsPreviousAccounts() async {
        let accounts = [AuthAccount(provider: "xai", email: "ok@x.ai", authIndex: "a")]
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
}

private final class FakeClient: CLIProxyClientProtocol, @unchecked Sendable {
    var accounts: [AuthAccount]
    var weekly: [String: Result<WeeklyQuota, Error>]
    var accountsError: Error?

    init(accounts: [AuthAccount], weekly: [String: Result<WeeklyQuota, Error>]) {
        self.accounts = accounts
        self.weekly = weekly
    }

    func fetchXAIAccounts() async throws -> [AuthAccount] {
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
}
