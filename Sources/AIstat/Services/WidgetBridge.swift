import Foundation
import AIstatShared

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Publishes a privacy-safe quota snapshot for the desktop widget extension.
enum WidgetBridge {
    static func publish(
        accounts: [AccountQuota],
        sub2Usage: Sub2APIUsage?,
        sub2Error: String?,
        globalError: String?,
        isConfigured: Bool,
        updatedAt: Date
    ) {
        let entries = accounts.map { item -> WidgetAccountEntry in
            WidgetAccountEntry(
                id: item.id,
                provider: item.account.provider,
                displayName: item.account.displayName,
                status: AccountQuotaStatus.resolved(for: item),
                remainingPercent: item.weekly?.remainingPercent,
                periodEnd: item.weekly?.periodEnd,
                errorMessage: item.errorMessage,
                isDisabled: item.account.disabled,
                isUnavailable: item.account.unavailable
            )
        }

        var balanceText: String?
        var planName: String?
        if let usage = sub2Usage {
            if let balance = usage.availableBalance {
                balanceText = formattedBalance(balance, unit: usage.unit)
            }
            planName = usage.planName
        }

        let snapshot = WidgetSnapshot(
            updatedAt: updatedAt,
            isConfigured: isConfigured,
            globalError: globalError,
            accounts: entries,
            sub2BalanceText: balanceText,
            sub2PlanName: planName,
            sub2Error: sub2Error
        )

        do {
            try WidgetDataStore.save(snapshot)
        } catch {
            // Widget publish must never break the menu bar refresh path.
            return
        }

        reloadTimelines()
    }

    static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private static func formattedBalance(_ value: Double, unit: String?) -> String {
        let amount = String(format: "%.2f", value)
        let normalizedUnit = (unit ?? "USD").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedUnit == "USD" || normalizedUnit == "$" {
            return "$\(amount)"
        }
        return "\(amount) \(normalizedUnit)"
    }
}
