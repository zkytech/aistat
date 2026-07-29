import AppKit
import SwiftUI

struct AccountQuotaRow: View {
    let item: AccountQuota
    let isHighlighted: Bool
    let onHoverChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            providerIcon

            statusIndicator
                .accessibilityLabel(statusAccessibilityLabel)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.account.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(resetCountdownText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    remainingProgressBar
                    Text(remainingText)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(remainingColor)
                        .lineLimit(1)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .help(detailHelpText)
    }

    private var remainingProgressBar: some View {
        let fraction = (item.weekly?.remainingPercent ?? 0) / 100

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(remainingBarColor)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var remainingBarColor: Color {
        guard let remaining = item.weekly?.remainingPercent else {
            return item.errorMessage == nil ? Color.secondary.opacity(0.35) : Color.red.opacity(0.55)
        }
        if remaining <= 0 { return .red }
        if remaining <= 20 { return .orange }
        return .accentColor
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let provider = SubscriptionProvider.resolve(from: item.account.provider) {
            ProviderIconView(provider: provider, size: 14)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("未知订阅类型")
        }
    }

    private var statusIndicator: some View {
        Image(systemName: statusSymbolName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(statusColor)
            .frame(width: 12, height: 12)
    }

    private var statusSymbolName: String {
        switch statusText {
        case "disabled":
            return "minus.circle.fill"
        case "error":
            return "exclamationmark.triangle.fill"
        case "exhausted":
            return "xmark.circle.fill"
        case "unavailable":
            return "slash.circle.fill"
        default:
            return "circle.fill"
        }
    }

    /// Priority: disabled → fetch error → weekly exhausted → unavailable → original status → active.
    private var statusText: String {
        AccountQuotaStatus.resolved(for: item)
    }

    private var statusColor: Color {
        AccountQuotaStatus.color(for: statusText)
    }

    private var statusAccessibilityLabel: String {
        "状态 \(statusText)"
    }

    private var remainingText: String {
        if item.errorMessage != nil {
            return "!!"
        }
        guard let remaining = item.weekly?.remainingPercent else {
            return "--"
        }
        return String(format: "%.0f%%", remaining)
    }

    private var remainingColor: Color {
        guard let remaining = item.weekly?.remainingPercent else {
            return item.errorMessage == nil ? .secondary : .red
        }
        if remaining <= 0 { return .red }
        if remaining <= 20 { return .orange }
        return .primary
    }

    private var resetCountdownText: String {
        guard let periodEnd = item.weekly?.periodEnd else {
            return item.errorMessage == nil ? "重置 --" : "获取失败"
        }
        return RelativeResetFormatter.string(until: periodEnd)
    }

    private var accessibilitySummary: String {
        let providerName = SubscriptionProvider.resolve(from: item.account.provider)?.displayName
            ?? item.account.provider
        return "\(providerName) \(item.account.displayName)，剩余 \(remainingText)，\(resetCountdownText)，状态 \(statusText)"
    }

    private var detailHelpText: String {
        var lines = [item.account.displayName, "状态：\(statusText)"]
        if let weekly = item.weekly, let remaining = weekly.remainingPercent {
            lines.append(String(format: "周剩余：%.0f%%", remaining))
        }
        if let end = item.weekly?.periodEnd {
            lines.append("重置时间：\(DisplayDateFormatter.string(from: end))")
        }
        if let errorMessage = item.errorMessage {
            lines.append("错误：\(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }
}

struct AccountQuotaDetailView: View {
    let item: AccountQuota

    private var statusText: String {
        AccountQuotaStatus.resolved(for: item)
    }

    private var statusColor: Color {
        AccountQuotaStatus.color(for: statusText)
    }

    private var statusSymbolName: String {
        switch statusText {
        case "disabled":
            return "minus.circle.fill"
        case "error":
            return "exclamationmark.triangle.fill"
        case "exhausted":
            return "xmark.circle.fill"
        case "unavailable":
            return "slash.circle.fill"
        default:
            return "circle.fill"
        }
    }

    var body: some View {
        // Match MenuBarContentView layout + MenuBarExtra frosted material.
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        .background {
            MenuBarStyleMaterialBackground()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.account.displayName) 账号详情")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let provider = SubscriptionProvider.resolve(from: item.account.provider) {
                ProviderIconView(provider: provider, size: 14)
                    .frame(width: 16, height: 16)
            }

            Image(systemName: statusSymbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 12, height: 12)
                .accessibilityLabel("状态 \(statusText)")

            Text(item.account.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var content: some View {
        // No ScrollView: panel sizes to content so no scrollbar appears.
        VStack(alignment: .leading, spacing: 10) {
            weeklySection

            if let monthly = item.monthly {
                sectionDivider
                monthlySection(monthly)
            }

            if let weekly = item.weekly, !weekly.productUsage.isEmpty {
                sectionDivider
                productSection(weekly.productUsage)
            }

            if hasAccountDetails {
                sectionDivider
                accountSection
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Divider()
            .opacity(0.45)
            .padding(.vertical, 2)
    }

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("周额度", systemImage: "calendar.badge.clock")

            if let weekly = item.weekly {
                detailRow(
                    "剩余",
                    weekly.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "--",
                    valueColor: remainingColor(for: weekly.remainingPercent)
                )
                detailRow(
                    "已用",
                    weekly.usedPercent.map { String(format: "%.0f%%", $0) } ?? "--"
                )
                if let start = weekly.periodStart {
                    detailRow("周期开始", DisplayDateFormatter.string(from: start))
                }
                if let end = weekly.periodEnd {
                    detailRow("重置时间", DisplayDateFormatter.string(from: end))
                    detailRow("距重置", RelativeResetFormatter.string(until: end))
                }
            } else if let errorMessage = item.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                Text("暂无周限额数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func monthlySection(_ monthly: MonthlyQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("月度额度", systemImage: "creditcard")
            detailRow("剩余", currency(monthly.remainingCents))
            detailRow("总额", currency(monthly.limitCents))
            if let remainingPercent = monthly.remainingPercent {
                detailRow(
                    "剩余比例",
                    String(format: "%.0f%%", remainingPercent),
                    valueColor: remainingColor(for: remainingPercent)
                )
            }
        }
    }

    private func productSection(_ products: [ProductUsage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("产品用量", systemImage: "square.grid.2x2")
            ForEach(products) { product in
                detailRow(
                    product.product,
                    product.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "--",
                    valueColor: remainingColor(for: product.remainingPercent)
                )
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("账号信息", systemImage: "info.circle")

            if let message = nonEmpty(item.account.statusMessage) {
                detailRow("状态说明", message)
            }
            if let retry = nonEmpty(item.account.nextRetryAfter) {
                detailRow("下次重试", retry)
            }
            if let success = item.account.success {
                detailRow("成功请求", "\(success)")
            }
            if let failed = item.account.failed {
                detailRow("失败请求", "\(failed)")
            }
            detailRow("Auth Index", item.account.authIndex)
        }
    }

    private var hasAccountDetails: Bool {
        nonEmpty(item.account.statusMessage) != nil
            || nonEmpty(item.account.nextRetryAfter) != nil
            || item.account.success != nil
            || item.account.failed != nil
            || !item.account.authIndex.isEmpty
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }

    private func detailRow(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func remainingColor(for remaining: Double?) -> Color {
        guard let remaining else { return .secondary }
        if remaining <= 0 { return .red }
        if remaining <= 20 { return .orange }
        return .primary
    }

    private func currency(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Frosted material matching MenuBarExtra `.window` chrome for floating panels.
struct MenuBarStyleMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // `.popover` is the closest public material to MenuBarExtra window glass.
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = true
    }
}

enum AccountQuotaStatus {
    static func resolved(for item: AccountQuota) -> String {
        if item.account.disabled {
            return "disabled"
        }
        if item.errorMessage != nil {
            return "error"
        }
        if item.weekly?.isExhausted == true {
            return "exhausted"
        }
        if item.account.unavailable {
            return "unavailable"
        }
        if let status = item.account.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return status
        }
        return "active"
    }

    static func color(for statusText: String) -> Color {
        switch statusText {
        case "disabled":
            return .secondary
        case "exhausted", "unavailable", "error":
            return .red
        default:
            return .green
        }
    }
}

enum RelativeResetFormatter {
    /// Compact countdown for the account list, e.g. `2天4时`, `3时12分`, `45分`.
    static func string(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 {
            return "已到期"
        }

        let totalMinutes = Int(seconds.rounded(.down)) / 60
        if totalMinutes < 1 {
            return "即将重置"
        }

        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 {
                return "\(days)天\(hours)时"
            }
            return "\(days)天"
        }
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)时\(minutes)分"
            }
            return "\(hours)时"
        }
        return "\(minutes)分"
    }
}
