import XCTest
@testable import AgentStatus

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

    func testFetchXAIAccountsFiltersAndHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/v0/management/auth-files")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), CLIProxyClient.managementUserAgent)

            let body = """
            [
              {"provider":"xai","email":"a@x.ai","auth_index":"x1","status":"active"},
              {"provider":"openai","email":"b@o.ai","auth_index":"o1"}
            ]
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let client = makeClient()
        let accounts = try await client.fetchXAIAccounts()
        XCTAssertEqual(accounts.map(\.authIndex), ["x1"])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testFetchWeeklyQuotaRequestBodyAndHeaders() async throws {
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
        let weekly = try await client.fetchWeeklyQuota(authIndex: "x1")
        XCTAssertEqual(weekly.usedPercent, 34)
        XCTAssertEqual(weekly.remainingPercent, 66)
    }

    private func makeClient() -> CLIProxyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let appConfig = AppConfiguration(baseURL: "https://example.test", managementKey: "test-key", refreshIntervalSeconds: 300)
        return CLIProxyClient(configuration: appConfig, session: session)
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
