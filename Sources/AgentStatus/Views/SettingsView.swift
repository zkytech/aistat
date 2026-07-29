import SwiftUI

private enum SettingsPlatform: String, CaseIterable, Identifiable {
    case cliproxyapi
    case sub2api

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cliproxyapi: return "CLIProxyAPI"
        case .sub2api: return "Sub2API"
        }
    }

    var subtitle: String {
        switch self {
        case .cliproxyapi: return "当前已接入 · Management API"
        case .sub2api: return "预留 · 尚未接入"
        }
    }

    var systemImage: String {
        switch self {
        case .cliproxyapi: return "server.rack"
        case .sub2api: return "arrow.triangle.2.circlepath.circle"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .cliproxyapi: return true
        case .sub2api: return false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: QuotaStore

    @State private var selectedPlatform: SettingsPlatform = .cliproxyapi
    @State private var baseURL: String = ""
    @State private var managementKey: String = ""
    @State private var refreshIntervalSeconds: Int = AppConfiguration.defaultRefreshIntervalSeconds
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isSaving = false

    private let minimumRefreshSeconds = Int(QuotaStore.minimumRefreshInterval)

    var body: some View {
        HSplitView {
            platformSidebar
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)

            detailPane
                .frame(minWidth: 360)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: loadFromStore)
    }

    private var platformSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("平台")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(SettingsPlatform.allCases) { platform in
                    Button {
                        selectedPlatform = platform
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: platform.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(platform.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedPlatform == platform ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    selectedPlatform == platform ? Color.accentColor.opacity(0.35) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(platform.title)，\(platform.subtitle)")
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Text("后续可在此扩展更多平台连接。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedPlatform {
        case .cliproxyapi:
            cliproxyForm
        case .sub2api:
            unavailablePlatformView
        }
    }

    private var cliproxyForm: some View {
        Form {
            Section("连接") {
                LabeledContent("Base URL") {
                    TextField("https://127.0.0.1:8317", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }

                LabeledContent("Management Key") {
                    SecureField("仅保存在本地", text: $managementKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }

            Section("刷新") {
                Stepper(value: $refreshIntervalSeconds, in: minimumRefreshSeconds...3600, step: 30) {
                    Text("自动刷新 \(refreshIntervalSeconds) 秒")
                }
                Text("手动刷新最短间隔 \(minimumRefreshSeconds) 秒；自动刷新不低于该值。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("操作") {
                HStack(spacing: 12) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 8)
                        } else {
                            Text("保存并刷新")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)

                    Button("重新加载本地配置") {
                        reloadFromDisk()
                    }
                    .disabled(isSaving)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            Section("配置文件") {
                Text(AppConfigurationStore.configURL.path)
                    .font(.system(size: 11).monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Text("密钥仅保存在本机 Application Support，不会上传。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var unavailablePlatformView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(selectedPlatform.title, systemImage: selectedPlatform.systemImage)
                .font(.system(size: 16, weight: .semibold))

            Text("该平台尚未接入。当前版本只支持 CLIProxyAPI Management API。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("后续接入时会在这里配置 endpoint、凭据与账号同步策略，并与左侧平台列表并列。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func loadFromStore() {
        baseURL = store.configuration.baseURL
        managementKey = store.configuration.managementKey
        refreshIntervalSeconds = max(store.configuration.refreshIntervalSeconds, minimumRefreshSeconds)
    }

    private func reloadFromDisk() {
        store.reloadConfigurationFromDisk()
        loadFromStore()
        statusMessage = "已从本地配置重新加载"
        isError = false
    }

    private func save() {
        isSaving = true
        defer { isSaving = false }

        var configuration = AppConfiguration(
            baseURL: baseURL,
            managementKey: managementKey,
            refreshIntervalSeconds: max(refreshIntervalSeconds, minimumRefreshSeconds)
        )
        if configuration.refreshIntervalSeconds <= 0 {
            configuration.refreshIntervalSeconds = AppConfiguration.defaultRefreshIntervalSeconds
        }

        do {
            try store.updateConfiguration(configuration)
            refreshIntervalSeconds = configuration.refreshIntervalSeconds
            statusMessage = "已保存到 Application Support 并开始刷新"
            isError = false
        } catch {
            statusMessage = error.localizedDescription
            isError = true
        }
    }
}
