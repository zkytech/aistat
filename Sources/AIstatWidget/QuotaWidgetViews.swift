import SwiftUI
import WidgetKit
import AIstatShared

// MARK: - Entry views by family

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWidgetEntry

    var body: some View {
        let content = Group {
            switch family {
            case .systemSmall:
                SmallQuotaWidgetView(entry: entry)
            case .systemMedium:
                MediumQuotaWidgetView(entry: entry)
            case .systemLarge:
                LargeQuotaWidgetView(entry: entry)
            default:
                MediumQuotaWidgetView(entry: entry)
            }
        }

        if #available(macOS 14.0, *) {
            content
                .containerBackground(for: .widget) {
                    // Subtle layered fill; system glass material sits underneath on macOS.
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.03),
                            WidgetTheme.accent.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        } else {
            content
                .padding(0)
                .background(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.03),
                            WidgetTheme.accent.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

// MARK: - Small: single KPI hero

/// Compact “tightest account” card — large remaining %, status, reset countdown.
struct SmallQuotaWidgetView: View {
    let entry: QuotaWidgetEntry

    var body: some View {
        if !entry.snapshot.isConfigured {
            emptyChrome(
                title: "未选择展示源",
                message: "编辑小组件，选择要展示的账号"
            )
        } else if let account = entry.snapshot.tightestAccount ?? entry.snapshot.accounts.first {
            VStack(alignment: .leading, spacing: WidgetTheme.spaceSM) {
                HStack(spacing: WidgetTheme.spaceXS) {
                    WidgetProviderGlyph(kind: account.providerKind, size: 11)
                    WidgetStatusDot(status: account.status)
                    Text(account.providerKind.displayName)
                        .font(WidgetTheme.labelFont())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("1/\(entry.snapshot.accounts.count)")
                        .font(WidgetTheme.monoSmall())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("展示 1 / \(entry.snapshot.accounts.count) 个账号")
                }

                Spacer(minLength: 0)

                Text(remainingDisplay(for: account))
                    .font(WidgetTheme.kpiFont(size: 32))
                    .foregroundStyle(WidgetTheme.remainingTextColor(for: account.remainingPercent))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .accessibilityLabel("剩余 \(remainingDisplay(for: account))")

                Text(account.displayName)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                WidgetProgressBar(
                    fraction: (account.remainingPercent ?? 0) / 100,
                    tint: WidgetTheme.remainingColor(for: account.remainingPercent),
                    height: WidgetTheme.progressHeight
                )

                HStack {
                    Text("剩余额度")
                        .font(WidgetTheme.captionFont())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(resetText(for: account))
                        .font(WidgetTheme.monoSmall())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(WidgetTheme.spaceMD)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(smallAccessibility(account))
        } else if let error = entry.snapshot.globalError {
            emptyChrome(title: "加载失败", message: error)
        } else {
            emptyChrome(title: "暂无账号", message: "刷新后将显示额度")
        }
    }

    private func remainingDisplay(for account: WidgetAccountEntry) -> String {
        if account.errorMessage != nil { return "!!" }
        return WidgetTheme.remainingText(account.remainingPercent)
    }

    private func resetText(for account: WidgetAccountEntry) -> String {
        if account.errorMessage != nil { return "获取失败" }
        guard let end = account.periodEnd else { return "重置 --" }
        return WidgetResetFormatter.string(until: end, now: entry.date)
    }

    private func smallAccessibility(_ account: WidgetAccountEntry) -> String {
        "\(account.providerKind.displayName) \(account.displayName)，剩余 \(remainingDisplay(for: account))，\(resetText(for: account))，状态 \(account.status)"
    }
}

// MARK: - Medium: multi-row list + Sub2 strip

struct MediumQuotaWidgetView: View {
    let entry: QuotaWidgetEntry

    private var rows: [WidgetAccountEntry] {
        WidgetAccountPresentation.rows(
            from: entry.snapshot.accounts,
            limit: WidgetAccountPresentation.mediumLimit
        )
    }

    var body: some View {
        if !entry.snapshot.isConfigured {
            emptyChrome(
                title: "未选择展示源",
                message: "编辑此小组件，选择要展示的 CLIProxyAPI 账号与余额账号"
            )
        } else {
            VStack(alignment: .leading, spacing: WidgetTheme.spaceSM) {
                headerStrip

                if rows.isEmpty {
                    Spacer(minLength: 0)
                    emptyInline(
                        title: entry.snapshot.globalError != nil ? "加载失败" : "暂无账号",
                        message: entry.snapshot.globalError ?? "支持 OpenAI / Claude / Grok"
                    )
                    Spacer(minLength: 0)
                } else {
                    VStack(spacing: WidgetTheme.spaceXS) {
                        ForEach(rows) { account in
                            AccountRowView(account: account, now: entry.date, compact: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(WidgetTheme.spaceMD)
        }
    }

    private var headerStrip: some View {
        HStack(spacing: WidgetTheme.spaceSM) {
            Label("账号额度", systemImage: "chart.bar.fill")
                .font(WidgetTheme.titleFont())
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            Text("\(rows.count)/\(entry.snapshot.accounts.count)")
                .font(WidgetTheme.monoSmall())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("展示 \(rows.count) / \(entry.snapshot.accounts.count) 个账号")

            MediumSub2Strip(entries: entry.snapshot.sub2Entries)

            Text(updatedCaption)
                .font(WidgetTheme.monoSmall())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var updatedCaption: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entry.snapshot.updatedAt)
    }
}

// MARK: - Large: fuller list + empty/error guidance

struct LargeQuotaWidgetView: View {
    let entry: QuotaWidgetEntry

    private var rows: [WidgetAccountEntry] {
        WidgetAccountPresentation.rows(
            from: entry.snapshot.accounts,
            limit: WidgetAccountPresentation.largeLimit
        )
    }


    var body: some View {
        if !entry.snapshot.isConfigured {
            emptyChrome(
                title: "未选择展示源",
                message: "编辑此小组件，选择要展示的 CLIProxyAPI 账号与余额账号。"
            )
        } else {
            VStack(alignment: .leading, spacing: WidgetTheme.spaceMD) {
                largeHeader

                if let globalError = entry.snapshot.globalError, rows.isEmpty {
                    emptyInline(title: "无法加载账号", message: globalError)
                    Spacer(minLength: 0)
                } else if rows.isEmpty {
                    emptyInline(title: "暂无 OpenAI / Claude / Grok 账号", message: "确认已选择的 CLIProxyAPI 已登录对应账号后刷新。")
                    Spacer(minLength: 0)
                } else {
                    VStack(spacing: WidgetTheme.spaceSM) {
                        ForEach(rows) { account in
                            AccountRowView(account: account, now: entry.date, compact: false)
                            if account.id != rows.last?.id {
                                Divider().opacity(WidgetTheme.dividerOpacity)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                footerMeta
            }
            .padding(WidgetTheme.spaceLG)
        }
    }

    private var largeHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: WidgetTheme.spaceSM) {
            VStack(alignment: .leading, spacing: 2) {
                Label("AIstat 额度", systemImage: "chart.bar.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(summaryLine)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            LargeWidgetChrome.sub2Badge(snapshot: entry.snapshot)
        }
    }

    private var summaryLine: String {
        if rows.isEmpty {
            return "等待数据"
        }
        return "展示 \(rows.count)/\(entry.snapshot.accounts.count) 个账号"
    }

    private var footerMeta: some View {
        LargeWidgetChrome.footer(updatedAt: entry.snapshot.updatedAt)
    }
}

// MARK: - Large dashboard entry (ring grid widget)

struct DashboardWidgetEntryView: View {
    let entry: QuotaWidgetEntry

    var body: some View {
        let content = LargeDashboardQuotaWidgetView(entry: entry)

        if #available(macOS 14.0, *) {
            content
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.03),
                            WidgetTheme.accent.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        } else {
            content
                .background(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.03),
                            WidgetTheme.accent.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

// MARK: - Large dashboard: battery-style rings per account

/// systemLarge 仪表盘：2×3 环形格子，语言对齐 iOS 电量小组件。
struct LargeDashboardQuotaWidgetView: View {
    let entry: QuotaWidgetEntry

    private var cells: [WidgetAccountEntry] {
        WidgetAccountPresentation.rows(
            from: entry.snapshot.accounts,
            limit: WidgetAccountPresentation.dashboardLimit
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 72), spacing: WidgetTheme.spaceSM),
            count: cells.count <= 4 ? 2 : 3
        )
    }

    var body: some View {
        if !entry.snapshot.isConfigured {
            emptyChrome(
                title: "未选择展示源",
                message: "编辑此小组件，选择要展示的 CLIProxyAPI 账号与余额账号。"
            )
        } else {
            VStack(alignment: .leading, spacing: WidgetTheme.spaceLG) {
                dashboardHeader

                if let globalError = entry.snapshot.globalError, cells.isEmpty {
                    emptyInline(title: "无法加载账号", message: globalError)
                    Spacer(minLength: 0)
                } else if cells.isEmpty {
                    emptyInline(
                        title: "暂无 OpenAI / Claude / Grok 账号",
                        message: "确认 CLIProxyAPI 已登录对应账号后刷新。"
                    )
                    Spacer(minLength: 0)
                } else {
                    LazyVGrid(columns: columns, spacing: WidgetTheme.spaceMD) {
                        ForEach(cells) { account in
                            AccountRingCell(account: account, now: entry.date)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, WidgetTheme.spaceLG)
            .padding(.top, WidgetTheme.spaceLG)
            .padding(.bottom, WidgetTheme.spaceMD)
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: WidgetTheme.spaceMD) {
            VStack(alignment: .leading, spacing: WidgetTheme.spaceXS) {
                Label("额度仪表盘", systemImage: "circle.circle")
                    .font(.system(size: 15, weight: .semibold))
                Text(summaryLine)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            LargeWidgetChrome.sub2Badge(snapshot: entry.snapshot)
        }
        .padding(.bottom, WidgetTheme.spaceXS)
    }

    private var summaryLine: String {
        if cells.isEmpty {
            return "等待数据"
        }
        return "展示 \(cells.count)/\(entry.snapshot.accounts.count) 个账号"
    }
}

// MARK: - Shared large chrome (list + dashboard)

/// Compact Sub2 strip for medium widget header (up to 2 balances).
private struct MediumSub2Strip: View {
    let entries: [WidgetSub2Entry]

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else if entries.count == 1, let entry = entries.first {
            single(entry)
        } else {
            HStack(spacing: 6) {
                ForEach(entries.prefix(2)) { entry in
                    single(entry)
                }
                if entries.count > 2 {
                    Text("+\(entries.count - 2)")
                        .font(WidgetTheme.captionFont())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func single(_ entry: WidgetSub2Entry) -> some View {
        if let err = entry.error {
            Text("\(entry.displayLabel) 错误")
                .font(WidgetTheme.captionFont())
                .foregroundStyle(WidgetTheme.statusCritical)
                .help(err)
                .lineLimit(1)
        } else if let balance = entry.balanceText {
            HStack(spacing: 3) {
                Image(systemName: "creditcard")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(entry.displayLabel)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(balance)
                    .font(WidgetTheme.monoCaption())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let daily = entry.dailyUsageText {
                    Text("今日 \(daily)")
                        .font(WidgetTheme.captionFont())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("\(entry.displayLabel) 余额 \(balance)今日消费 \(entry.dailyUsageText ?? "无")")
        }
    }
}

private enum LargeWidgetChrome {
    @ViewBuilder
    static func sub2Badge(snapshot: WidgetSnapshot) -> some View {
        let entries = snapshot.sub2Entries
        if entries.isEmpty {
            // Fallback for legacy snapshots without sub2Entries.
            if let err = snapshot.sub2Error {
                Label("Sub2 错误", systemImage: "exclamationmark.triangle.fill")
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(WidgetTheme.statusCritical)
                    .help(err)
            } else if let balance = snapshot.sub2BalanceText {
                legacyBadge(balance: balance, planName: snapshot.sub2PlanName)
            }
        } else if entries.count == 1, let entry = entries.first {
            singleBadge(entry)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(entries.prefix(3)) { entry in
                    multiRow(entry)
                }
                if entries.count > 3 {
                    Text("+\(entries.count - 3)")
                        .font(WidgetTheme.captionFont())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private static func singleBadge(_ entry: WidgetSub2Entry) -> some View {
        if let err = entry.error {
            Label("\(entry.displayLabel) 错误", systemImage: "exclamationmark.triangle.fill")
                .font(WidgetTheme.captionFont())
                .foregroundStyle(WidgetTheme.statusCritical)
                .help(err)
        } else if let balance = entry.balanceText {
            VStack(alignment: .trailing, spacing: 2) {
                Text(balance)
                    .font(WidgetTheme.kpiFont(size: 18))
                Text(entry.displayLabel)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let daily = entry.dailyUsageText {
                    Text("今日 \(daily)")
                        .font(WidgetTheme.monoCaption())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.displayLabel) \(balance)今日消费 \(entry.dailyUsageText ?? "无")")
        }
    }

    @ViewBuilder
    private static func multiRow(_ entry: WidgetSub2Entry) -> some View {
        if let err = entry.error {
            Text("\(entry.displayLabel)：错误")
                .font(WidgetTheme.captionFont())
                .foregroundStyle(WidgetTheme.statusCritical)
                .help(err)
                .lineLimit(1)
        } else if let balance = entry.balanceText {
            HStack(spacing: 4) {
                Text(entry.displayLabel)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(balance)
                    .font(WidgetTheme.monoCaption())
                    .lineLimit(1)
                if let daily = entry.dailyUsageText {
                    Text("今日 \(daily)")
                        .font(WidgetTheme.captionFont())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("\(entry.displayLabel) \(balance)今日消费 \(entry.dailyUsageText ?? "无")")
        }
    }

    private static func legacyBadge(balance: String, planName: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(balance)
                .font(WidgetTheme.kpiFont(size: 18))
            Text(planName?.isEmpty == false ? planName! : "Sub2API")
                .font(WidgetTheme.captionFont())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sub2API \(balance)")
    }

    static func footer(updatedAt: Date) -> some View {
        HStack {
            Text("更新于 \(DisplayClock.string(from: updatedAt))")
                .font(WidgetTheme.monoSmall())
                .foregroundStyle(.tertiary)
            Spacer()
            Text("颜色仅作辅助 · 以数字为准")
                .font(WidgetTheme.captionFont())
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    }
}

// MARK: - Account row

struct AccountRowView: View {
    let account: WidgetAccountEntry
    let now: Date
    var compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: WidgetTheme.spaceSM) {
            WidgetProviderGlyph(kind: account.providerKind, size: compact ? 11 : 12)
            WidgetStatusDot(status: account.status)

            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                HStack(spacing: WidgetTheme.spaceSM) {
                    Text(account.displayName)
                        .font(compact ? WidgetTheme.captionFont() : WidgetTheme.labelFont())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(resetText)
                        .font(WidgetTheme.monoSmall())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: WidgetTheme.spaceSM) {
                    WidgetProgressBar(
                        fraction: (account.remainingPercent ?? 0) / 100,
                        tint: WidgetTheme.remainingColor(for: account.remainingPercent),
                        height: compact ? WidgetTheme.progressHeight : WidgetTheme.progressHeightLarge
                    )
                    Text(remainingText)
                        .font(WidgetTheme.monoCaption())
                        .foregroundStyle(WidgetTheme.remainingTextColor(for: account.remainingPercent))
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(account.providerKind.displayName) \(account.displayName)，剩余 \(remainingText)，\(resetText)，状态 \(account.status)"
        )
    }

    private var remainingText: String {
        if account.errorMessage != nil { return "!!" }
        return WidgetTheme.remainingText(account.remainingPercent)
    }

    private var resetText: String {
        if account.errorMessage != nil { return "获取失败" }
        guard let end = account.periodEnd else { return "重置 --" }
        return WidgetResetFormatter.string(until: end, now: now)
    }
}

// MARK: - Account ring cell (dashboard)

/// One battery-style ring tile: gauge + provider + truncated name + reset countdown.
struct AccountRingCell: View {
    let account: WidgetAccountEntry
    let now: Date

    private var hasError: Bool { account.errorMessage != nil }

    var body: some View {
        VStack(spacing: 3) {
            WidgetRingGauge(
                remaining: account.remainingPercent,
                hasError: hasError,
                size: 58,
                lineWidth: 6.5,
                centerFontSize: 13
            )

            HStack(spacing: 3) {
                WidgetProviderGlyph(kind: account.providerKind, size: 9)
                WidgetStatusDot(status: account.status)
                Text(account.providerKind.displayName)
                    .font(WidgetTheme.captionFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(account.displayName)
                .font(WidgetTheme.captionFont())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(resetText)
                .font(WidgetTheme.monoSmall())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(account.providerKind.displayName) \(account.displayName)，剩余 \(remainingText)，\(resetText)，状态 \(account.status)"
        )
    }

    private var remainingText: String {
        if hasError { return "!!" }
        return WidgetTheme.remainingText(account.remainingPercent)
    }

    private var resetText: String {
        if hasError { return "获取失败" }
        guard let end = account.periodEnd else { return "重置 --" }
        return WidgetResetFormatter.string(until: end, now: now)
    }
}

// MARK: - Empty / error chrome

private func emptyChrome(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: WidgetTheme.spaceSM) {
        Label(title, systemImage: "chart.bar.fill")
            .font(WidgetTheme.titleFont())
        Text(message)
            .font(WidgetTheme.captionFont())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
    }
    .padding(WidgetTheme.spaceMD)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)。\(message)")
}

private func emptyInline(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: WidgetTheme.spaceXS) {
        Text(title)
            .font(WidgetTheme.labelFont())
        Text(message)
            .font(WidgetTheme.captionFont())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, WidgetTheme.spaceSM)
}

private enum DisplayClock {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
