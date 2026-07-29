import XCTest
@testable import AgentStatus

final class ModelDecodingTests: XCTestCase {
    func testAuthAccountDisplayNameFallback() throws {
        let json = """
        {
          "provider": "xai",
          "auth_index": "a1",
          "account": "fallback@example.com",
          "status": "active"
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder().decode(AuthAccount.self, from: json)
        XCTAssertEqual(account.displayName, "fallback@example.com")
        XCTAssertEqual(account.authIndex, "a1")
    }

    func testAuthFilesArrayAndFilterFields() throws {
        let json = """
        [
          {
            "provider": "xai",
            "email": "one@example.com",
            "auth_index": "1",
            "status": "active",
            "unavailable": false,
            "disabled": false
          },
          {
            "provider": "openai",
            "email": "two@example.com",
            "auth_index": "2"
          }
        ]
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthFilesResponse.self, from: json)
        XCTAssertEqual(response.accounts.count, 2)
        XCTAssertEqual(response.accounts[0].email, "one@example.com")
    }

    func testWeeklyBodyObject() throws {
        let json = """
        {
          "body": {
            "config": {
              "creditUsagePercent": 66.5,
              "currentPeriod": {
                "start": "2026-07-20T00:00:00Z",
                "end": "2026-07-27T00:00:00.123Z"
              },
              "productUsage": [
                {"product": "grok", "usagePercent": "70"}
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIProxyResponse.self, from: json)
        let weekly = response.body.config.weeklyQuota
        XCTAssertEqual(weekly.usedPercent, 66.5)
        XCTAssertEqual(weekly.remainingPercent, 33.5)
        XCTAssertEqual(weekly.productUsage.count, 1)
        XCTAssertEqual(weekly.productUsage[0].usagePercent, 70)
        XCTAssertNotNil(weekly.periodStart)
        XCTAssertNotNil(weekly.periodEnd)
    }

    func testWeeklyBodyJSONStringAndMissingPercent() throws {
        let nested = """
        {"config":{"currentPeriod":{"start":"2026-07-20T00:00:00Z","end":"2026-07-27T00:00:00Z"},"productUsage":[]}}
        """
        let escaped = nested.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {"body":"\(escaped)"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIProxyResponse.self, from: json)
        XCTAssertNil(response.body.config.weeklyQuota.usedPercent)
        XCTAssertNil(response.body.config.weeklyQuota.remainingPercent)
        XCTAssertFalse(response.body.config.weeklyQuota.isExhausted)
    }

    func testWeeklyBodyWithMissingProductUsagePercent() throws {
        let nested = """
        {"config":{"creditUsagePercent":68.0,"currentPeriod":{"start":"2026-07-28T14:25:29.139195+00:00","end":"2026-08-04T14:25:29.139195+00:00"},"productUsage":[{"product":"GrokBuild","usagePercent":68.0},{"product":"GrokChat"}]}}
        """
        let escaped = nested.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {"body":"\(escaped)"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIProxyResponse.self, from: json)
        let weekly = response.body.config.weeklyQuota
        XCTAssertEqual(weekly.usedPercent, 68)
        XCTAssertEqual(weekly.productUsage.count, 2)
        XCTAssertEqual(weekly.productUsage[0].usagePercent, 68)
        XCTAssertNil(weekly.productUsage[1].usagePercent)
        XCTAssertNotNil(weekly.periodEnd)
    }

    func testMonthlyQuota() throws {
        let json = """
        {
          "body": {
            "config": {
              "monthlyLimit": {"val": 2000},
              "used": {"val": 450}
            }
          }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(APIProxyResponse.self, from: json)
        XCTAssertEqual(response.body.config.monthlyQuota?.limitCents, 2000)
        XCTAssertEqual(response.body.config.monthlyQuota?.usedCents, 450)
    }
}
