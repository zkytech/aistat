import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            Label("Grok 额度", systemImage: "chart.bar.fill")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
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
        if let globalError = store.globalError, store.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(globalError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                Text("打开设置检查 baseURL 与 managementKey。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if store.accounts.isEmpty {
            Text(store.isRefreshing ? "正在加载账号…" : "暂无 xAI 账号")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let globalError = store.globalError {
                    Text(globalError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                }

                ForEach(store.accounts) { item in
                    AccountQuotaRow(item: item)
                    if item.id != store.accounts.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
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
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

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
            return "最短刷新间隔 3 分钟，下次可刷新 \(DisplayDateFormatter.string(from: next))"
        }
        return "手动刷新（最短间隔 3 分钟）"
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: AgentStatusApp.settingsWindowID)

        // MenuBarExtra can leave the new window behind; force key/front after open.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "设置" || window.identifier?.rawValue == AgentStatusApp.settingsWindowID {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
