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
            .onChange(of: hoveredAccountID) { _ in
                syncDetailPanel()
            }
            .onChange(of: store.accounts) { _ in
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
            if store.configuration.isSub2APIConfigured || store.sub2APIUsage != nil || store.sub2APIError != nil {
                sub2APISection
            }

            if let globalError = store.globalError, store.accounts.isEmpty, !store.configuration.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text(globalError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text("打开设置检查 baseURL 与 managementKey。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if store.configuration.isConfigured {
                if store.accounts.isEmpty {
                    Text(store.isRefreshing ? "正在加载账号…" : "暂无 OpenAI / Claude / Grok 账号")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        if let globalError = store.globalError {
                            Text(globalError)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .padding(.bottom, 6)
                        }

                        ForEach(store.accounts) { item in
                            AccountQuotaRow(
                                item: item,
                                isHighlighted: hoveredAccountID == item.id,
                                onHoverChange: { isInside in
                                    if isInside {
                                        selectHoveredAccount(item.id)
                                    }
                                }
                            )
                            if item.id != store.accounts.last?.id {
                                Divider()
                                    .opacity(0.45)
                                    .padding(.leading, 36)
                            }
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

    private var sub2APISection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("Sub2API", systemImage: "creditcard")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let planName = store.sub2APIUsage?.planName, !planName.isEmpty {
                    Text(planName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let error = store.sub2APIError {
                    Text("错误")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .help(error)
                } else if let usage = store.sub2APIUsage, let balance = usage.availableBalance {
                    Text(formattedBalance(balance, unit: usage.unit))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .accessibilityLabel("Sub2API 可用余额 \(formattedBalance(balance, unit: usage.unit))")
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

            if store.configuration.isConfigured {
                Divider()
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
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
                Task { await store.refresh(force: false) }
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
        if let next = store.nextRefreshAvailableAt, next > Date() {
            return "最短刷新间隔 1 分钟，下次可刷新 \(DisplayDateFormatter.string(from: next))"
        }
        return "手动刷新（最短间隔 1 分钟）"
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
