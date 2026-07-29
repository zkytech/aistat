import SwiftUI

struct AccountQuotaRow: View {
    let item: AccountQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusDot
                    .accessibilityLabel(statusAccessibilityLabel)

                Text(item.account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.account.displayName)

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            if let weekly = item.weekly {
                weeklySection(weekly)
            } else if let errorMessage = item.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else {
                Text("暂无周限额数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let monthly = item.monthly {
                Text(monthlyText(monthly))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    /// Priority: disabled → fetch error → weekly exhausted → unavailable → original status → active.
    private var statusText: String {
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

    private var statusColor: Color {
        switch statusText {
        case "disabled":
            return .secondary
        case "exhausted", "unavailable", "error":
            return .red
        default:
            return .green
        }
    }

    private var statusAccessibilityLabel: String {
        "状态 \(statusText)"
    }

    @ViewBuilder
    private func weeklySection(_ weekly: WeeklyQuota) -> some View {
        let remaining = weekly.remainingPercent
        let used = weekly.usedPercent

        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: (remaining ?? 0) / 100.0)
                .tint(progressTint(remaining: remaining))

            HStack {
                Text(remainingText(remaining))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Spacer()
                Text(usedText(used))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let end = weekly.periodEnd {
                Text("重置 \(DisplayDateFormatter.string(from: end))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !weekly.productUsage.isEmpty {
                Text(productUsageText(weekly.productUsage))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func productUsageText(_ items: [ProductUsage]) -> String {
        items.map { item in
            if let remaining = item.remainingPercent {
                return "\(item.product) 剩 \(Int(remaining.rounded()))%"
            }
            return item.product
        }.joined(separator: " · ")
    }

    private func usedText(_ used: Double?) -> String {
        guard let used else { return "已用 --" }
        return String(format: "已用 %.0f%%", used)
    }

    private func remainingText(_ remaining: Double?) -> String {
        guard let remaining else { return "剩余 --" }
        return String(format: "剩余 %.0f%%", remaining)
    }

    private func progressTint(remaining: Double?) -> Color {
        guard let remaining else { return .accentColor }
        if remaining <= 0 { return .red }
        if remaining <= 20 { return .orange }
        return .accentColor
    }

    private func monthlyText(_ monthly: MonthlyQuota) -> String {
        let remaining = Double(monthly.remainingCents) / 100.0
        let limit = Double(monthly.limitCents) / 100.0
        if let remainingPercent = monthly.remainingPercent {
            return String(format: "月度剩余 $%.2f / $%.2f（%.0f%%）", remaining, limit, remainingPercent)
        }
        return String(format: "月度剩余 $%.2f / $%.2f", remaining, limit)
    }
}
