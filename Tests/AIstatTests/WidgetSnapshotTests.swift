import XCTest
@testable import AIstatShared

final class WidgetSnapshotTests: XCTestCase {
    func testTightestAccountPicksLowestRemaining() {
        let snapshot = WidgetSnapshot(
            isConfigured: true,
            accounts: [
                WidgetAccountEntry(
                    id: "a",
                    provider: "xai",
                    displayName: "high",
                    status: "active",
                    remainingPercent: 80
                ),
                WidgetAccountEntry(
                    id: "b",
                    provider: "claude",
                    displayName: "low",
                    status: "active",
                    remainingPercent: 12
                ),
                WidgetAccountEntry(
                    id: "c",
                    provider: "openai",
                    displayName: "disabled",
                    status: "disabled",
                    remainingPercent: 1,
                    isDisabled: true
                )
            ]
        )

        XCTAssertEqual(snapshot.tightestAccount?.id, "b")
    }

    func testResetFormatter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inTwoDays = now.addingTimeInterval(2 * 24 * 3600 + 3 * 3600)
        XCTAssertEqual(WidgetResetFormatter.string(until: inTwoDays, now: now), "2天3时")

        let past = now.addingTimeInterval(-60)
        XCTAssertEqual(WidgetResetFormatter.string(until: past, now: now), "已到期")
    }

    func testSnapshotRoundTrip() throws {
        let original = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isConfigured: true,
            globalError: nil,
            accounts: [
                WidgetAccountEntry(
                    id: "1",
                    provider: "xai",
                    displayName: "you@x.ai",
                    sourceName: "家里",
                    status: "active",
                    remainingPercent: 34,
                    periodEnd: Date(timeIntervalSince1970: 1_700_100_000)
                )
            ],
            sub2Entries: [
                WidgetSub2Entry(id: "s1", name: "主账户", balanceText: "$1.00", planName: "Pro")
            ],
            sub2BalanceText: "$1.00",
            sub2PlanName: "Pro"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.accounts.count, 1)
        XCTAssertEqual(decoded.accounts[0].remainingPercent, 34)
        XCTAssertEqual(decoded.accounts[0].sourceName, "家里")
        XCTAssertEqual(decoded.sub2BalanceText, "$1.00")
        XCTAssertEqual(decoded.sub2Entries.count, 1)
        XCTAssertEqual(decoded.sub2Entries[0].name, "主账户")
        XCTAssertEqual(decoded.tightestAccount?.displayName, "you@x.ai")
    }

    func testLegacySingleSub2FieldsMigrateIntoEntries() throws {
        let legacy = """
        {
          "updatedAt": 1700000000,
          "isConfigured": true,
          "accounts": [],
          "sub2BalanceText": "$2.50",
          "sub2PlanName": "Lite",
          "sub2Error": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(WidgetSnapshot.self, from: legacy)
        XCTAssertEqual(decoded.sub2Entries.count, 1)
        XCTAssertEqual(decoded.sub2Entries[0].balanceText, "$2.50")
        XCTAssertEqual(decoded.primarySub2Entry?.planName, "Lite")
    }

    func testFilteredSnapshotBySourceIDs() {
        let full = WidgetSnapshot(
            isConfigured: true,
            accounts: [
                WidgetAccountEntry(
                    id: "a1",
                    provider: "xai",
                    displayName: "a",
                    sourceID: "cli-1",
                    sourceName: "家里",
                    status: "active",
                    remainingPercent: 10
                ),
                WidgetAccountEntry(
                    id: "a2",
                    provider: "xai",
                    displayName: "b",
                    sourceID: "cli-2",
                    sourceName: "公司",
                    status: "active",
                    remainingPercent: 20
                )
            ],
            sub2Entries: [
                WidgetSub2Entry(id: "s1", name: "主账户", balanceText: "$1"),
                WidgetSub2Entry(id: "s2", name: "备用", balanceText: "$2")
            ]
        )

        let empty = full.filtered(cliProxySourceIDs: [], balanceSourceID: nil)
        XCTAssertFalse(empty.isConfigured)
        XCTAssertTrue(empty.accounts.isEmpty)
        XCTAssertTrue(empty.sub2Entries.isEmpty)

        let partial = full.filtered(cliProxySourceIDs: ["cli-1"], balanceSourceID: "s2")
        XCTAssertTrue(partial.isConfigured)
        XCTAssertEqual(partial.accounts.map(\.id), ["a1"])
        XCTAssertEqual(partial.sub2Entries.map(\.id), ["s2"])
        XCTAssertEqual(partial.sub2BalanceText, "$2")
    }

    func testFilteredSnapshotBySingleBalanceSourceKeepsOnlyOne() {
        let full = WidgetSnapshot(
            isConfigured: true,
            accounts: [],
            sub2Entries: [
                WidgetSub2Entry(id: "s1", name: "主账户", balanceText: "$1"),
                WidgetSub2Entry(id: "d1", name: "DeepSeek", balanceText: "¥20.00")
            ]
        )

        let single = full.filtered(cliProxySourceIDs: [], balanceSourceID: "d1")
        XCTAssertTrue(single.isConfigured)
        XCTAssertEqual(single.sub2Entries.map(\.id), ["d1"])
        XCTAssertEqual(single.sub2BalanceText, "¥20.00")

        let none = full.filtered(cliProxySourceIDs: [], balanceSourceID: nil)
        XCTAssertFalse(none.isConfigured)
        XCTAssertTrue(none.sub2Entries.isEmpty)
    }

    func testDeepSeekSourceKindRoundTrip() {
        let info = WidgetSourceInfo(id: "d1", name: "DeepSeek", kind: WidgetSourceKind.deepseek.rawValue)
        XCTAssertEqual(info.sourceKind, .deepseek)
        XCTAssertEqual(info.displayName, "DeepSeek")

        let noName = WidgetSourceInfo(id: "d2", name: "", kind: WidgetSourceKind.deepseek.rawValue)
        XCTAssertEqual(noName.displayName, "DeepSeek")
    }

    func testProviderResolve() {
        XCTAssertEqual(WidgetProviderKind.resolve(from: "xai"), .grok)
        XCTAssertEqual(WidgetProviderKind.resolve(from: "anthropic"), .claude)
        XCTAssertEqual(WidgetProviderKind.resolve(from: "codex"), .openai)
        XCTAssertEqual(WidgetProviderKind.resolve(from: "nope"), .unknown)
        XCTAssertEqual(WidgetProviderKind.openai.iconResourceName, "ProviderIcon-openai")
        XCTAssertEqual(WidgetProviderKind.claude.iconResourceName, "ProviderIcon-claude")
        XCTAssertEqual(WidgetProviderKind.grok.iconResourceName, "ProviderIcon-grok")
        XCTAssertNil(WidgetProviderKind.unknown.iconResourceName)
    }

    func testWidgetAccountPresentationLimitsLargeWidgetToFiveAccounts() {
        let accounts = (0..<8).map { index in
            WidgetAccountEntry(
                id: "\(index)",
                provider: "xai",
                displayName: "account-\(index)",
                status: "active"
            )
        }

        XCTAssertEqual(WidgetAccountPresentation.mediumLimit, 3)
        XCTAssertEqual(WidgetAccountPresentation.largeLimit, 5)
        XCTAssertEqual(WidgetAccountPresentation.dashboardLimit, 6)
        XCTAssertEqual(
            WidgetAccountPresentation.rows(
                from: accounts,
                limit: WidgetAccountPresentation.largeLimit
            ).map(\.id),
            ["0", "1", "2", "3", "4"]
        )
        XCTAssertEqual(
            WidgetAccountPresentation.rows(
                from: accounts,
                limit: WidgetAccountPresentation.dashboardLimit
            ).map(\.id),
            ["0", "1", "2", "3", "4", "5"]
        )
    }
}
