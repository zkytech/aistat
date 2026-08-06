import XCTest
@testable import AIstat

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

    func testCodexUsageResponsePicksTightestWindow() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 10, "limit_window_seconds": 18000, "reset_at": 100},
            "secondary_window": {"used_percent": 90, "limit_window_seconds": 604800, "reset_at": 200}
          }
        }
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        let weekly = usage.asWeeklyQuota()
        XCTAssertEqual(weekly.usedPercent, 90)
        XCTAssertEqual(weekly.remainingPercent, 10)
        XCTAssertEqual(weekly.periodEnd, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(weekly.productUsage.map(\.product), ["5 小时限额", "周限额"])
    }

    func testClaudeUsageResponseParsesWindows() throws {
        let json = """
        {
          "five_hour": {"utilization": "12.5", "resets_at": "2026-07-29T10:00:00Z"},
          "seven_day": {"utilization": 40, "resets_at": "2026-08-01T00:00:00Z"},
          "seven_day_opus": {"utilization": 5, "resets_at": "2026-08-01T00:00:00Z"}
        }
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: json)
        let weekly = usage.asWeeklyQuota()
        XCTAssertEqual(weekly.usedPercent, 40)
        XCTAssertEqual(weekly.remainingPercent, 60)
        XCTAssertEqual(weekly.productUsage.count, 3)
        XCTAssertEqual(weekly.productUsage.map(\.product), ["5 小时限额", "7 天限额", "7 天 Opus"])
    }

    func testSubscriptionProviderResolve() {
        XCTAssertEqual(SubscriptionProvider.resolve(from: "xai"), .grok)
        XCTAssertEqual(SubscriptionProvider.resolve(from: "CODEX"), .openai)
        XCTAssertEqual(SubscriptionProvider.resolve(from: "openai"), .openai)
        XCTAssertEqual(SubscriptionProvider.resolve(from: "anthropic"), .claude)
        XCTAssertEqual(SubscriptionProvider.resolve(from: "claude"), .claude)
        XCTAssertNil(SubscriptionProvider.resolve(from: "gemini"))
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

    func testSub2APIDailyUsageText() throws {
        let withDaily = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"subscription","unit":"USD","subscription":{"daily_usage_usd":1.23,"daily_limit_usd":5,"monthly_usage_usd":7.25,"monthly_limit_usd":20}}
        """.utf8))
        XCTAssertEqual(withDaily.dailyUsageText, "$1.23")

        let noDaily = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"unrestricted","unit":"USD","balance":12.16,"remaining":12.16}
        """.utf8))
        XCTAssertNil(noDaily.dailyUsageText)
    }

    func testSub2APIUsageTodayDrivesDailyText() throws {
        // actual_cost preferred over list-price cost.
        let actual = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"unrestricted","unit":"USD","usage":{"today":{"actual_cost":3.130292295,"cost":66.62117325}}}
        """.utf8))
        XCTAssertEqual(actual.dailyUsageText, "$3.13")

        // Only cost present → fallback, and 0 must still be shown.
        let zero = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"unrestricted","unit":"USD","usage":{"today":{"cost":0}}}
        """.utf8))
        XCTAssertEqual(zero.dailyUsageText, "$0.00")

        // Actual cost of exactly 0 shows instead of a string amount.
        let zeroActual = try JSONDecoder().decode(Sub2APIUsage.self, from: Data("""
        {"mode":"unrestricted","unit":"USD","usage":{"today":{"actual_cost":0,"cost":0}}}
        """.utf8))
        XCTAssertEqual(zeroActual.dailyUsageText, "$0.00")
    }

    func testDeepSeekBalanceDecodesStringAmountsAndPicksCurrency() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {"currency": "CNY", "total_balance": "50", "granted_balance": "0", "topped_up_balance": "50"},
            {"currency": "USD", "total_balance": "3.5", "granted_balance": "0", "topped_up_balance": "3.5"}
          ]
        }
        """.data(using: .utf8)!

        let balance = try JSONDecoder().decode(DeepSeekBalance.self, from: json)
        XCTAssertEqual(balance.isAvailable, true)
        // USD with positive balance wins.
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.totalBalance ?? -1, 3.5, accuracy: 0.0001)
        XCTAssertNil(balance.unavailableMessage)
    }

    func testDeepSeekBalanceEmptyInfoIsUnavailable() throws {
        let json = Data("""
        {"is_available": false, "balance_infos": []}
        """.utf8)

        let balance = try JSONDecoder().decode(DeepSeekBalance.self, from: json)
        XCTAssertEqual(balance.isAvailable, false)
        XCTAssertNil(balance.currency)
        XCTAssertNil(balance.totalBalance)
        XCTAssertEqual(balance.unavailableMessage, "账户不可用")
    }

    func testBalanceFormatter() {
        XCTAssertEqual(BalanceFormatter.string(12.4, unit: "USD"), "$12.40")
        XCTAssertEqual(BalanceFormatter.string(12.4, unit: "$"), "$12.40")
        XCTAssertEqual(BalanceFormatter.string(25, unit: "CNY"), "¥25.00")
        XCTAssertEqual(BalanceFormatter.string(25, unit: "RMB"), "¥25.00")
        XCTAssertEqual(BalanceFormatter.string(12.4, unit: "EUR"), "€12.40")
        XCTAssertEqual(BalanceFormatter.string(12.4, unit: "GBP"), "£12.40")
        XCTAssertEqual(BalanceFormatter.string(25, unit: "JPY"), "25.00 JPY")
        XCTAssertEqual(BalanceFormatter.string(25, unit: nil), "$25.00")
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

    func testAccountQuotaSorterPutsWeeklyZeroedAccountsLast() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "zero-near@x.ai", name: "zero-near.json", authIndex: "zero-near"),
                // Closest reset, but weekly usage already at 0% → must sort last.
                weekly: WeeklyQuota(usedPercent: 0, periodStart: nil, periodEnd: now.addingTimeInterval(50), productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "far@x.ai", name: "far.json", authIndex: "far"),
                weekly: WeeklyQuota(usedPercent: 10, periodStart: nil, periodEnd: now.addingTimeInterval(10_000), productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "near@x.ai", name: "near.json", authIndex: "near"),
                weekly: WeeklyQuota(usedPercent: 20, periodStart: nil, periodEnd: now.addingTimeInterval(100), productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "missing@x.ai", name: "missing.json", authIndex: "missing"),
                weekly: WeeklyQuota(usedPercent: 40, periodStart: nil, periodEnd: nil, productUsage: [])
            ),
            AccountQuota(
                account: AuthAccount(provider: "xai", email: "zero-far@x.ai", name: "zero-far.json", authIndex: "zero-far"),
                weekly: WeeklyQuota(usedPercent: 0, periodStart: nil, periodEnd: now.addingTimeInterval(20_000), productUsage: [])
            )
        ]

        let sorted = AccountQuotaSorter.sortByRefreshProximity(items, now: now)
        XCTAssertEqual(
            sorted.map(\.account.authIndex),
            ["near", "far", "missing", "zero-near", "zero-far"]
        )

        let priorities = AccountQuotaSorter.prioritiesByProximity(items, now: now)
        XCTAssertEqual(
            priorities.map(\.name),
            ["near.json", "far.json", "missing.json", "zero-near.json", "zero-far.json"]
        )
        XCTAssertEqual(priorities.map(\.priority), [5, 4, 3, 2, 1])
    }

    func testWeeklyUsageZeroedDetection() {
        XCTAssertTrue(WeeklyQuota(usedPercent: 0, periodStart: nil, periodEnd: nil, productUsage: []).isWeeklyUsageZeroed)
        XCTAssertFalse(WeeklyQuota(usedPercent: 0.1, periodStart: nil, periodEnd: nil, productUsage: []).isWeeklyUsageZeroed)
        XCTAssertFalse(WeeklyQuota(usedPercent: 100, periodStart: nil, periodEnd: nil, productUsage: []).isWeeklyUsageZeroed)
        XCTAssertFalse(WeeklyQuota(usedPercent: nil, periodStart: nil, periodEnd: nil, productUsage: []).isWeeklyUsageZeroed)
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
