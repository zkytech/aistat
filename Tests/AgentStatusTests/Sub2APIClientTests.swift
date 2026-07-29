import XCTest
@testable import AgentStatus

final class Sub2APIClientTests: XCTestCase {
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

    func testFetchUsageRequestAndDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://sub2api.example/v1/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-sub2-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), Sub2APIClient.userAgent)

            let body = """
            {"mode":"unrestricted","planName":"按量","unit":"USD","balance":12.15740932,"remaining":12.15740932}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let usage = try await makeClient().fetchUsage()
        XCTAssertEqual(usage.mode, "unrestricted")
        XCTAssertEqual(usage.availableBalance, 12.15740932)
        XCTAssertEqual(usage.unit, "USD")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testFetchUsagePropagatesHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let body = Data("unauthorized".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        do {
            _ = try await makeClient().fetchUsage()
            XCTFail("expected error")
        } catch let error as Sub2APIClientError {
            XCTAssertEqual(error, .httpStatus(401, "unauthorized"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeClient() -> Sub2APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let appConfig = AppConfiguration(
            baseURL: "https://example.test",
            managementKey: "test-key",
            sub2APIBaseURL: "https://sub2api.example",
            sub2APIKey: "test-sub2-key",
            refreshIntervalSeconds: 300
        )
        return Sub2APIClient(configuration: appConfig, session: session)
    }
}
