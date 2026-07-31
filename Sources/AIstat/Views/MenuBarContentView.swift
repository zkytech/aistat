import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore
    @Environment(\.openWindow) private var openWindow

    @State private var hoveredAccountID: String?
    @State private var hostWindow: NSWindow?
    @State private var detailPanelController = AccountDetailHoverPanelController()

    private let mainPanelWidth: CGFloat = 360

    var body: some View {
        mainPanel
            .frame(width: mainPanelWidth)
            .background(HostWindowReader { window in
                if hostWindow !== window {
                    hostWindow = window
                    if window == nil {
                        clearHoveredAccount()
                    } else if hoveredAccountID != nil {
                        syncDetailPanel()
                    }
                }
            })
            .onChange(of: hoveredAccountID) {
                syncDetailPanel()
            }
            .onChange(of: store.accounts) {
                if let hoveredAccountID, store.accounts.contains(where: { $0.id == hoveredAccountID }) {
                    syncDetailPanel()
                } else if hoveredAccountID != nil {
                    clearHoveredAccount()
                }
            }
            .onDisappear {
                clearHoveredAccount()
            }
    }
    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(.vertical, 8)
    }

    private var detailItem: AccountQuota? {
        guard let hoveredAccountID else { return nil }
        return store.accounts.first(where: { $0.id == hoveredAccountID })
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("账号额度", systemImage: "chart.bar.fill")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.sub2APIEntries.isEmpty || store.configuration.isSub2APIConfigured {
                sub2APISection
            }

            if let globalError = store.globalError,
               store.accountGroups.isEmpty,
               !store.configuration.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text(globalError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text("打开设置检查 CLIProxyAPI / Sub2API 连接。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if store.configuration.isConfigured {
                if store.accountGroups.isEmpty {
                    Text(store.isRefreshing ? "正在加载账号…" : "暂无 OpenAI / Claude / Grok 账号")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.accountGroups) { group in
                            cliProxyGroupSection(group)
                        }
                    }
                }
            } else if !store.configuration.isSub2APIConfigured {
                Text("请先在设置中配置 CLIProxyAPI 或 Sub2API。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cliProxyGroupSection(_ group: CLIProxyAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(group.connectionName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let error = group.error, !error.isEmpty {
                    Text("!")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                        .help(error)
                }
            }
            .padding(.horizontal, 4)

            if let error = group.error, group.accounts.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
            }

            if group.accounts.isEmpty {
                Text(store.isRefreshing ? "正在加载…" : "暂无订阅账号")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.accounts) { item in
                        AccountQuotaRow(
                            item: item,
                            isHighlighted: hoveredAccountID == item.id,
                            onHoverChange: { isInside in
                                if isInside {
                                    selectHoveredAccount(item.id)
                                }
                            }
                        )
                        if item.id != group.accounts.last?.id {
                            Divider()
                                .opacity(0.45)
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    private var sub2APISection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(displaySub2Entries) { entry in
                HStack(spacing: 10) {
                    Label {
                        Text(entry.connectionName)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "creditcard")
                    }
                    .font(.system(size: 12, weight: .semibold))

                    Spacer(minLength: 8)

                    if let planName = entry.usage?.planName, !planName.isEmpty {
                        Text(planName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let error = entry.error {
                        Text("错误")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .help(error)
                    } else if let usage = entry.usage, let balance = usage.availableBalance {
                        Text(formattedBalance(balance, unit: usage.unit))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .accessibilityLabel("\(entry.connectionName) 可用余额 \(formattedBalance(balance, unit: usage.unit))")
                    } else if store.isRefreshing {
                        Text("加载中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("--")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if store.configuration.isConfigured {
                Divider()
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Prefer live results; if not yet refreshed, show configured connection placeholders.
    private var displaySub2Entries: [Sub2APIUsageEntry] {
        if !store.sub2APIEntries.isEmpty {
            return store.sub2APIEntries
        }
        return store.configuration.sub2APIConnections
            .filter(\.isConfigured)
            .map {
                Sub2APIUsageEntry(
                    connectionID: $0.id,
                    connectionName: $0.displayName,
                    usage: nil,
                    error: nil
                )
            }
    }

    private func formattedBalance(_ value: Double, unit: String?) -> String {
        let amount = String(format: "%.2f", value)
        let normalizedUnit = (unit ?? "USD").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedUnit == "USD" || normalizedUnit == "$" {
            return "$\(amount)"
        }
        return "\(amount) \(normalizedUnit)"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(!store.canManualRefresh)
            .help(refreshHelpText)

            Text(lastRefreshText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("设置") {
                openSettingsWindow()
            }
            .help("打开设置")

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .help("退出")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .controlSize(.small)
    }

    private var lastRefreshText: String {
        guard let lastRefreshAt = store.lastRefreshAt else {
            return "尚未刷新"
        }
        return "上次 \(DisplayDateFormatter.string(from: lastRefreshAt))"
    }

    private var refreshHelpText: String {
        if store.isRefreshing {
            return "正在刷新…"
        }
        return "立即刷新（不受自动刷新间隔限制）"
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: AIstatApp.settingsWindowID)

        // MenuBarExtra can leave the new window behind; force key/front after open.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "设置" || window.identifier?.rawValue == AIstatApp.settingsWindowID {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Row enter selects an account. Dismissal is owned by the floating panel
    /// controller using actual window geometry, so the main panel size never
    /// changes and leaving either surface closes the card.
    private func selectHoveredAccount(_ accountID: String) {
        hoveredAccountID = accountID
        syncDetailPanel()
    }

    private func clearHoveredAccount() {
        hoveredAccountID = nil
        detailPanelController.hide()
    }

    private func syncDetailPanel() {
        guard let detailItem else {
            detailPanelController.hide()
            return
        }

        detailPanelController.show(
            item: detailItem,
            relativeTo: hostWindow,
            onDismiss: {
                hoveredAccountID = nil
            }
        )
    }
}
