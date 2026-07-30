import WidgetKit
import SwiftUI
import AIstatShared

struct QuotaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    static var placeholder: QuotaWidgetEntry {
        QuotaWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                updatedAt: Date(),
                isConfigured: true,
                accounts: [
                    WidgetAccountEntry(
                        id: "demo-grok",
                        provider: "xai",
                        displayName: "you@example.com",
                        status: "active",
                        remainingPercent: 34,
                        periodEnd: Date().addingTimeInterval(2 * 24 * 3600)
                    ),
                    WidgetAccountEntry(
                        id: "demo-claude",
                        provider: "claude",
                        displayName: "claude@example.com",
                        status: "active",
                        remainingPercent: 72,
                        periodEnd: Date().addingTimeInterval(5 * 24 * 3600)
                    ),
                    WidgetAccountEntry(
                        id: "demo-openai",
                        provider: "openai",
                        displayName: "oai@example.com",
                        status: "active",
                        remainingPercent: 12,
                        periodEnd: Date().addingTimeInterval(36 * 3600)
                    ),
                    WidgetAccountEntry(
                        id: "demo-grok-2",
                        provider: "xai",
                        displayName: "alt@example.com",
                        status: "active",
                        remainingPercent: 88,
                        periodEnd: Date().addingTimeInterval(4 * 24 * 3600)
                    ),
                    WidgetAccountEntry(
                        id: "demo-claude-2",
                        provider: "claude",
                        displayName: "team@example.com",
                        status: "exhausted",
                        remainingPercent: 0,
                        periodEnd: Date().addingTimeInterval(20 * 3600)
                    ),
                    WidgetAccountEntry(
                        id: "demo-openai-2",
                        provider: "openai",
                        displayName: "plus@example.com",
                        status: "active",
                        remainingPercent: 51,
                        periodEnd: Date().addingTimeInterval(6 * 24 * 3600)
                    )
                ],
                sub2Entries: [
                    WidgetSub2Entry(
                        id: "demo-sub2",
                        name: "主账户",
                        balanceText: "$12.40",
                        planName: "Pro"
                    )
                ],
                sub2BalanceText: "$12.40",
                sub2PlanName: "Pro"
            )
        )
    }
}

struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaWidgetEntry>) -> Void) {
        let entry = makeEntry()
        // Widgets are system-throttled; 15 min keeps data reasonably fresh
        // while main app also calls reloadAllTimelines() after each refresh.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry() -> QuotaWidgetEntry {
        let snapshot = WidgetDataStore.load() ?? .empty
        return QuotaWidgetEntry(date: Date(), snapshot: snapshot)
    }
}

struct QuotaWidget: Widget {
    let kind = "AIstatQuotaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("账号额度")
        .description("在桌面查看 AI 订阅周额度剩余、状态与重置倒计时。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Large-only dashboard: each account as a battery-style remaining ring.
struct QuotaDashboardWidget: Widget {
    let kind = "AIstatQuotaDashboardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuotaTimelineProvider()) { entry in
            DashboardWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("额度仪表盘")
        .description("大号环形图仪表盘：每个账号一枚电量式剩余额度环。")
        .supportedFamilies([.systemLarge])
    }
}
