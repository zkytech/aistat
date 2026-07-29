import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
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
                Text("打开 Settings 检查 baseURL 与 managementKey。")
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
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
            .frame(maxHeight: 420)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.refresh(force: false) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .help("手动刷新（防抖 1.5 秒）")

            Text(lastRefreshText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Settings") {
                openSettingsWindow()
            }
            .help("打开设置")

            Button("Quit") {
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
        return "上次 \(lastRefreshAt.formatted(date: .omitted, time: .shortened))"
    }

    private func openSettingsWindow() {
        // macOS 14+ uses showSettingsWindow:; macOS 13 uses showPreferencesWindow:.
        let settingsSelector = Selector(("showSettingsWindow:"))
        if NSApp.responds(to: settingsSelector) {
            NSApp.sendAction(settingsSelector, to: nil, from: nil)
            return
        }
        let preferencesSelector = Selector(("showPreferencesWindow:"))
        if NSApp.responds(to: preferencesSelector) {
            NSApp.sendAction(preferencesSelector, to: nil, from: nil)
        }
    }
}
