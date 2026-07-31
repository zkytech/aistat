import Foundation
import AIstatShared

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Publishes a privacy-safe quota snapshot for the desktop widget extension.
enum WidgetBridge {
    static func publish(
        accounts: [AccountQuota],
        sub2Entries: [Sub2APIUsageEntry],
        sources: [WidgetSourceInfo],
        globalError: String?,
        isConfigured: Bool,
        updatedAt: Date
    ) {
        let widgetAccounts = accounts.map { item -> WidgetAccountEntry in
            WidgetAccountEntry(
                id: item.id,
                provider: item.account.provider,
                displayName: item.account.displayName,
                sourceID: item.connectionID.isEmpty ? nil : item.connectionID,
                sourceName: item.connectionName.isEmpty ? nil : item.connectionName,
                status: AccountQuotaStatus.resolved(for: item),
                remainingPercent: item.weekly?.remainingPercent,
                periodEnd: item.weekly?.periodEnd,
                errorMessage: item.errorMessage,
                isDisabled: item.account.disabled,
                isUnavailable: item.account.unavailable
            )
        }

        let widgetSub2: [WidgetSub2Entry] = sub2Entries.map { entry in
            var balanceText: String?
            var planName: String?
            if let usage = entry.usage {
                if let balance = usage.availableBalance {
                    balanceText = formattedBalance(balance, unit: usage.unit)
                }
                planName = usage.planName
            }
            return WidgetSub2Entry(
                id: entry.connectionID,
                name: entry.connectionName,
                balanceText: balanceText,
                planName: planName,
                error: entry.error
            )
        }

        // Keep legacy single fields filled for older tooling / partial readers.
        let primary = widgetSub2.first(where: { $0.balanceText != nil })
            ?? widgetSub2.first(where: { $0.error != nil })
            ?? widgetSub2.first

        let snapshot = WidgetSnapshot(
            updatedAt: updatedAt,
            isConfigured: isConfigured,
            globalError: globalError,
            accounts: widgetAccounts,
            sub2Entries: widgetSub2,
            sources: sources,
            sub2BalanceText: primary?.balanceText,
            sub2PlanName: primary?.planName,
            sub2Error: primary?.error
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
