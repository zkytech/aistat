import XCTest
@testable import AIstat

final class DeepSeekClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requests = []
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requests = []
        super.tearDown()
    }

    func testFetchBalanceRequestAndDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-ds-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), Sub2APIClient.userAgent)

            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "USD", "total_balance": "12.35", "granted_balance": "0", "topped_up_balance": "12.35"}
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let balance = try await makeClient().fetchBalance()
        XCTAssertEqual(balance.isAvailable, true)
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.totalBalance ?? -1, 12.35, accuracy: 0.0001)
        XCTAssertNil(balance.unavailableMessage)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testFetchBalancePrefersUsdWithPositiveBalance() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "CNY", "total_balance": "50"},
                {"currency": "USD", "total_balance": "3.5"},
                {"currency": "EUR", "total_balance": "0"}
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let balance = try await makeClient().fetchBalance()
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.totalBalance ?? -1, 3.5, accuracy: 0.0001)
    }

    func testFetchBalanceFallsBackToAnyPositiveThenUsdThenFirst() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "USD", "total_balance": "0"},
                {"currency": "CNY", "total_balance": "20"}
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        // Any > 0 wins over an empty USD row.
        let anyPositive = try await makeClient().fetchBalance()
        XCTAssertEqual(anyPositive.currency, "CNY")
        XCTAssertEqual(anyPositive.totalBalance ?? -1, 20, accuracy: 0.0001)
    }

    func testFetchBalancePrefersUsdWhenAllZero() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "EUR", "total_balance": "0"},
                {"currency": "USD", "total_balance": "0"}
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let balance = try await makeClient().fetchBalance()
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.totalBalance ?? -1, 0, accuracy: 0.0001)
    }

    func testUnavailableWithoutBalanceReportsError() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = """
            {"is_available": false, "balance_infos": []}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let balance = try await makeClient().fetchBalance()
        XCTAssertFalse(balance.isAvailable)
        XCTAssertNil(balance.totalBalance)
        XCTAssertEqual(balance.unavailableMessage, "账户不可用")
    }

    func testUnavailableButHasBalanceShowsBalance() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = """
            {"is_available": false, "balance_infos": [{"currency": "USD", "total_balance": "2.00"}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let balance = try await makeClient().fetchBalance()
        XCTAssertFalse(balance.isAvailable)
        XCTAssertEqual(balance.totalBalance ?? -1, 2.00, accuracy: 0.0001)
        XCTAssertNil(balance.unavailableMessage)
    }

    func testFetchBalancePropagatesHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let body = Data("unauthorized".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        do {
            _ = try await makeClient().fetchBalance()
            XCTFail("expected error")
        } catch let error as DeepSeekAPIClientError {
            XCTAssertEqual(error, .httpStatus(401, "unauthorized"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeClient() -> DeepSeekClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return DeepSeekClient(apiKey: "test-ds-key", session: session)
    }
}
