import XCTest
@testable import AIstat

final class CLIProxyClientTests: XCTestCase {
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

    func testFetchAccountsFiltersSupportedProviders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/v0/management/auth-files")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), CLIProxyClient.managementUserAgent)

            let body = """
            [
              {"provider":"xai","email":"a@x.ai","name":"a.json","auth_index":"x1","status":"active"},
              {"provider":"codex","email":"b@o.ai","name":"b.json","auth_index":"o1"},
              {"provider":"claude","email":"c@a.ai","name":"c.json","auth_index":"c1"},
              {"provider":"gemini","email":"d@g.ai","name":"d.json","auth_index":"g1"}
            ]
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let client = makeClient()
        let accounts = try await client.fetchAccounts()
        XCTAssertEqual(accounts.map(\.authIndex), ["x1", "o1", "c1"])
        XCTAssertEqual(accounts.first?.name, "a.json")
        XCTAssertEqual(accounts.first?.managementName, "a.json")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testFetchGrokWeeklyQuotaRequestBodyAndHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/v0/management/api-call")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), CLIProxyClient.managementUserAgent)

            let bodyData = try XCTUnwrap(request.httpBody ?? request.bodyStreamData())
            let object = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            XCTAssertEqual(object["authIndex"] as? String, "x1")
            XCTAssertEqual(object["method"] as? String, "GET")
            XCTAssertEqual(object["url"] as? String, CLIProxyClient.weeklyBillingURL)
            let headers = object["header"] as! [String: String]
            XCTAssertEqual(headers["Authorization"], "Bearer $TOKEN$")
            XCTAssertEqual(headers["user-agent"], CLIProxyClient.grokBillingUserAgent)
            XCTAssertEqual(headers["x-xai-token-auth"], "xai-grok-cli")

            let responseBody = """
            {"body":{"config":{"creditUsagePercent":34,"currentPeriod":{"start":"2026-07-20T00:00:00Z","end":"2026-07-27T00:00:00Z"},"productUsage":[]}}}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseBody)
        }

        let client = makeClient()
        let account = AuthAccount(provider: "xai", email: "a@x.ai", authIndex: "x1")
        let weekly = try await client.fetchWeeklyQuota(for: account)
        XCTAssertEqual(weekly.usedPercent, 34)
        XCTAssertEqual(weekly.remainingPercent, 66)
    }

    func testFetchCodexQuotaParsesPrimaryWindow() async throws {
        MockURLProtocol.requestHandler = { request in
            let bodyData = try XCTUnwrap(request.httpBody ?? request.bodyStreamData())
            let object = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            XCTAssertEqual(object["url"] as? String, CLIProxyClient.codexUsageURL)
            let headers = object["header"] as! [String: String]
            XCTAssertEqual(headers["User-Agent"], CLIProxyClient.codexUserAgent)

            let responseBody = """
            {
              "status_code": 200,
              "body": {
                "plan_type": "plus",
                "rate_limit": {
                  "allowed": true,
                  "limit_reached": false,
                  "primary_window": {
                    "used_percent": 40,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 3600,
                    "reset_at": 1700003600
                  },
                  "secondary_window": {
                    "used_percent": 15,
                    "limit_window_seconds": 604800,
                    "reset_at": 1700600000
                  }
                }
              }
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseBody)
        }

        let client = makeClient()
        let account = AuthAccount(provider: "codex", email: "b@o.ai", authIndex: "o1")
        let weekly = try await client.fetchWeeklyQuota(for: account)
        // Primary list metric is the most constrained window (highest used %).
        XCTAssertEqual(weekly.usedPercent, 40)
        XCTAssertEqual(weekly.remainingPercent, 60)
        XCTAssertEqual(weekly.periodEnd, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(weekly.productUsage.count, 2)
        XCTAssertEqual(weekly.productUsage.map(\.product), ["5 小时限额", "周限额"])
    }

    func testFetchClaudeQuotaParsesWindows() async throws {
        MockURLProtocol.requestHandler = { request in
            let bodyData = try XCTUnwrap(request.httpBody ?? request.bodyStreamData())
            let object = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            XCTAssertEqual(object["url"] as? String, CLIProxyClient.claudeUsageURL)
            let headers = object["header"] as! [String: String]
            XCTAssertEqual(headers["anthropic-beta"], "oauth-2025-04-20")

            let responseBody = """
            {
              "status_code": 200,
              "body": {
                "five_hour": {"utilization": 55.5, "resets_at": "2026-07-29T12:00:00Z"},
                "seven_day": {"utilization": 22, "resets_at": "2026-08-04T00:00:00Z"}
              }
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseBody)
        }

        let client = makeClient()
        let account = AuthAccount(provider: "claude", email: "c@a.ai", authIndex: "c1")
        let weekly = try await client.fetchWeeklyQuota(for: account)
        XCTAssertEqual(weekly.usedPercent, 55.5)
        XCTAssertEqual(weekly.remainingPercent, 44.5)
        XCTAssertEqual(weekly.productUsage.count, 2)
        XCTAssertEqual(weekly.productUsage[0].product, "5 小时限额")
        XCTAssertEqual(weekly.productUsage[0].usagePercent, 55.5)
        XCTAssertEqual(weekly.productUsage[1].product, "7 天限额")
        XCTAssertEqual(weekly.productUsage[1].usagePercent, 22)
    }

    func testFetchMonthlyQuotaOnlyForGrok() async throws {
        var seenURLs: [String] = []
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("api-call") == true {
                let bodyData = try XCTUnwrap(request.httpBody ?? request.bodyStreamData())
                let object = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
                seenURLs.append(object["url"] as? String ?? "")
                let responseBody = """
                {"body":{"config":{"monthlyLimit":{"val":15000},"used":{"val":3000}}}}
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, responseBody)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeClient()
        let monthly = try await client.fetchMonthlyQuota(for: AuthAccount(provider: "xai", authIndex: "x1"))
        XCTAssertEqual(monthly?.limitCents, 15_000)
        XCTAssertEqual(monthly?.usedCents, 3_000)

        let codexMonthly = try await client.fetchMonthlyQuota(for: AuthAccount(provider: "codex", authIndex: "o1"))
        XCTAssertNil(codexMonthly)
        XCTAssertEqual(seenURLs, [CLIProxyClient.monthlyBillingURL])
    }

    func testUpdateAuthPrioritiesSendsPatchWithNameAndDescendingPriority() async throws {
        var seen: [[String: Any]] = []
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/v0/management/auth-files/fields")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

            let bodyData = try XCTUnwrap(request.httpBody ?? request.bodyStreamData())
            let object = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            seen.append(object)

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let client = makeClient()
        try await client.updateAuthPriorities([
            (name: "near.json", priority: 2),
            (name: "far.json", priority: 1)
        ])

        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0]["name"] as? String, "near.json")
        XCTAssertEqual(seen[0]["priority"] as? Int, 2)
        XCTAssertEqual(seen[1]["name"] as? String, "far.json")
        XCTAssertEqual(seen[1]["priority"] as? Int, 1)
    }

    private func makeClient() -> CLIProxyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CLIProxyClient(
            baseURL: "https://example.test",
            managementKey: "test-key",
            session: session
        )
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requests.append(request)
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
