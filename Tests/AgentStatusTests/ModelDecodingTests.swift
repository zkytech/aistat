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
        XCTAssertEqual(account.managementName, "a1")
    }

    func testAuthAccountDecodesNameForPriorityUpdates() throws {
        let json = """
        {
          "provider": "xai",
          "email": "one@example.com",
          "name": "one.json",
          "auth_index": "1",
          "status": "active"
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder().decode(AuthAccount.self, from: json)
        XCTAssertEqual(account.name, "one.json")
        XCTAssertEqual(account.managementName, "one.json")
    }

    func testAuthFilesArrayAndFilterFields() throws {
        let json = """
        [
          {
            "provider": "xai",
            "email": "one@example.com",
            "name": "one.json",
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
        XCTAssertEqual(response.accounts[0].name, "one.json")
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
        XCTAssertEqual(weekly.productUsage[0].remainingPercent, 30)
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

    func testWeeklyQuotaFillsMissingPercentFromMonthly() {
        let weekly = WeeklyQuota(
            usedPercent: nil,
            periodStart: nil,
            periodEnd: Date(timeIntervalSince1970: 1_700_000_000),
            productUsage: []
        )
        let filled = weekly.fillingMissingUsage(from: MonthlyQuota(limitCents: 15_000, usedCents: 5_336))
        XCTAssertEqual(filled.usedPercent ?? -1, 35.57333333333334, accuracy: 0.0001)
        XCTAssertEqual(filled.remainingPercent ?? -1, 64.42666666666666, accuracy: 0.0001)
        XCTAssertEqual(filled.periodEnd, weekly.periodEnd)

        let kept = WeeklyQuota(usedPercent: 12, periodStart: nil, periodEnd: nil, productUsage: [])
            .fillingMissingUsage(from: MonthlyQuota(limitCents: 15_000, usedCents: 5_336))
        XCTAssertEqual(kept.usedPercent, 12)

        let stillMissing = weekly.fillingMissingUsage(from: nil)
        XCTAssertNil(stillMissing.usedPercent)
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
        XCTAssertEqual(weekly.remainingPercent, 32)
        XCTAssertEqual(weekly.productUsage.count, 2)
        XCTAssertEqual(weekly.productUsage[0].usagePercent, 68)
        XCTAssertEqual(weekly.productUsage[0].remainingPercent, 32)
        XCTAssertNil(weekly.productUsage[1].usagePercent)
        XCTAssertNotNil(weekly.periodEnd)
    }

    func testMonthlyQuotaRemaining() throws {
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
        let monthly = try XCTUnwrap(response.body.config.monthlyQuota)
        XCTAssertEqual(monthly.limitCents, 2000)
        XCTAssertEqual(monthly.usedCents, 450)
        XCTAssertEqual(monthly.remainingCents, 1550)
        XCTAssertEqual(monthly.remainingPercent, 77.5)
    }

    func testSub2APIUsageDecodesAllBalanceModes() throws {
        let unrestricted = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"unrestricted","planName":"按量","unit":"USD","balance":12.15740932,"remaining":12.15740932}
        """.utf8))
        XCTAssertEqual(unrestricted.availableBalance, 12.15740932)
        XCTAssertEqual(unrestricted.unit, "USD")

        let quotaLimited = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"quota_limited","quota":{"limit":100,"used":35.5,"remaining":64.5}}
        """.utf8))
        XCTAssertEqual(quotaLimited.availableBalance, 64.5)

        let subscription = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"subscription","subscription":{"monthly_usage_usd":7.25,"monthly_limit_usd":20}}
        """.utf8))
        XCTAssertEqual(subscription.availableBalance, 12.75)
    }
    func testDisplayDateFormatterUsesLocalWallClockFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 7, day: 29, hour: 12, minute: 1, second: 0)
        let date = calendar.date(from: components)!

        // Force formatter path with a temporary local timezone by constructing expected string from current TZ offset.
        // DisplayDateFormatter uses TimeZone.current; assert format shape and reconstructed components.
        let formatted = DisplayDateFormatter.string(from: date)
        let regex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#)
        let range = NSRange(location: 0, length: formatted.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: formatted, range: range))
        XCTAssertEqual(formatted.count, 19)
    }

    func testAccountQuotaSorterOrdersByAbsoluteDistanceToRefresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "far@x.ai", name: "far.json", authIndex: "far"),
                weekly: WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: now.addingTimeInterval(10_000), productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "near@x.ai", name: "near.json", authIndex: "near"),
                weekly: WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: now.addingTimeInterval(100), productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "expired@x.ai", name: "expired.json", authIndex: "expired"),
                weekly: WeeklyQuota(usedPercent: 30, periodStart: nil, periodEnd: now.addingTimeInterval(-50), productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "missing@x.ai", name: "missing.json", authIndex: "missing"),
                weekly: WeeklyQuota(usedPercent: 40, periodStart: nil, periodEnd: nil, productUsage: [])
            )
        ]

        let sorted = AccountQuotaSorter.sortByRefreshProximity(items, now: now)
        XCTAssertEqual(sorted.map(\.account.authIndex), ["expired", "near", "far", "missing"])

        let priorities = AccountQuotaSorter.prioritiesByProximity(items, now: now)
        XCTAssertEqual(priorities.map(\.name), ["expired.json", "near.json", "far.json", "missing.json"])
        XCTAssertEqual(priorities.map(\.priority), [4, 3, 2, 1])
    }

    func testRemainingPercentBoundaries() {
        XCTAssertEqual(WeeklyQuota(usedPercent: 0, periodStart: nil, periodEnd: nil, productUsage: []).remainingPercent, 100)
        XCTAssertEqual(WeeklyQuota(usedPercent: 100, periodStart: nil, periodEnd: nil, productUsage: []).remainingPercent, 0)
        XCTAssertEqual(WeeklyQuota(usedPercent: 34, periodStart: nil, periodEnd: nil, productUsage: []).remainingPercent, 66)
        XCTAssertNil(WeeklyQuota(usedPercent: nil, periodStart: nil, periodEnd: nil, productUsage: []).remainingPercent)
        XCTAssertTrue(WeeklyQuota(usedPercent: 100, periodStart: nil, periodEnd: nil, productUsage: []).isExhausted)
        XCTAssertFalse(WeeklyQuota(usedPercent: 99, periodStart: nil, periodEnd: nil, productUsage: []).isExhausted)
    }

    func testRelativeResetFormatterCompactCountdown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            RelativeResetFormatter.string(until: now.addingTimeInterval(2 * 24 * 3600 + 4 * 3600 + 30), now: now),
            "2天4时"
        )
        XCTAssertEqual(
            RelativeResetFormatter.string(until: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now),
            "3时12分"
        )
        XCTAssertEqual(
            RelativeResetFormatter.string(until: now.addingTimeInterval(45 * 60), now: now),
            "45分"
        )
        XCTAssertEqual(
            RelativeResetFormatter.string(until: now.addingTimeInterval(20), now: now),
            "即将重置"
        )
        XCTAssertEqual(
            RelativeResetFormatter.string(until: now.addingTimeInterval(-5), now: now),
            "已到期"
        )
    }
}
