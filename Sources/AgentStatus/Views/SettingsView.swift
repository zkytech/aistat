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
        case .cliproxyapi: return "Management API"
        case .sub2api: return "用量与余额"
        }
    }

    var description: String {
        switch self {
        case .cliproxyapi:
            return "连接 CLIProxyAPI 管理端，读取 xAI 账号的周额度与月度用量。"
        case .sub2api:
            return "连接 Sub2API，通过用量接口读取账户余额和已使用额度。"
        }
    }

    var systemImage: String {
        switch self {
        case .cliproxyapi: return "server.rack"
        case .sub2api: return "arrow.triangle.2.circlepath.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: QuotaStore

    @State private var selectedPlatform: SettingsPlatform = .cliproxyapi
    @State private var baseURL: String = ""
    @State private var managementKey: String = ""
    @State private var sub2APIBaseURL: String = ""
    @State private var sub2APIKey: String = ""
    @State private var refreshIntervalSeconds: Int = AppConfiguration.defaultRefreshIntervalSeconds
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isSaving = false

    private let minimumRefreshSeconds = Int(QuotaStore.minimumRefreshInterval)

    var body: some View {
        HSplitView {
            platformSidebar
                .frame(minWidth: 210, idealWidth: 220, maxWidth: 240)

            detailPane
                .frame(minWidth: 520)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear(perform: loadFromStore)
    }

    private var platformSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("数据源")
                    .font(.headline)
                Text("选择要配置的服务")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)

            VStack(spacing: 6) {
                ForEach(SettingsPlatform.allCases) { platform in
                    Button {
                        selectedPlatform = platform
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: platform.systemImage)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(selectedPlatform == platform ? Color.accentColor : .secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(platform.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            if isPlatformConfigured(platform) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("已配置")
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedPlatform == platform ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(platform.title)，\(platform.subtitle)")
                    .accessibilityAddTraits(selectedPlatform == platform ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 24)

            Label("密钥仅存储在本机", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    detailHeader
                    connectionSection
                    dataSourceNotesSection
                    refreshSection
                    configurationFileSection
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            actionBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: selectedPlatform.systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(selectedPlatform.title)
                        .font(.title2.weight(.semibold))
                    configurationStatus
                }
                Text(selectedPlatform.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configurationStatus: some View {
        let configured = isPlatformConfigured(selectedPlatform)
        return Label(configured ? "已配置" : "未配置", systemImage: configured ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.medium))
            .foregroundStyle(configured ? Color.green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private var connectionSection: some View {
        settingsSection(title: "连接配置", subtitle: "填写服务地址和访问凭据。") {
            switch selectedPlatform {
            case .cliproxyapi:
                settingsField("Base URL", hint: "CLIProxyAPI 管理服务地址") {
                    TextField("https://127.0.0.1:8317", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("CLIProxyAPI Base URL")
                }
                settingsField("Management Key", hint: "用于访问 Management API") {
                    SecureField("仅保存在本机", text: $managementKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("CLIProxyAPI Management Key")
                }
            case .sub2api:
                settingsField("Base URL", hint: "Sub2API 服务地址") {
                    TextField("https://aihub.top", text: $sub2APIBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Sub2API Base URL")
                }
                settingsField("API Key", hint: "作为 Bearer Token 发送") {
                    SecureField("仅保存在本机", text: $sub2APIKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Sub2API API Key")
                }
            }
        }
    }

    private var dataSourceNotesSection: some View {
        settingsSection(title: "数据来源", subtitle: "当前数据源使用的接口与范围。") {
            switch selectedPlatform {
            case .cliproxyapi:
                infoRow(icon: "person.2", text: "从 Management API 获取 xAI 账号列表。")
                infoRow(icon: "chart.bar", text: "逐账号读取周额度；可用时同时读取月度额度。")
            case .sub2api:
                infoRow(icon: "chart.bar", text: "从 GET /v1/usage 读取账户用量和余额。")
                infoRow(icon: "key", text: "请求使用 Authorization: Bearer <API Key>。")
            }
        }
    }

    private var refreshSection: some View {
        settingsSection(title: "自动刷新", subtitle: "该设置由所有数据源共用。") {
            HStack(spacing: 16) {
                Stepper(value: $refreshIntervalSeconds, in: minimumRefreshSeconds...3600, step: 30) {
                    Text("每 \(refreshIntervalSeconds) 秒")
                        .monospacedDigit()
                }
                Spacer(minLength: 16)
                Text("最短 \(minimumRefreshSeconds) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var configurationFileSection: some View {
        settingsSection(title: "配置文件", subtitle: "两个数据源保存在同一个本地配置文件中。") {
            Text(AppConfigurationStore.configURL.path)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            infoRow(icon: "lock", text: "访问凭据仅写入 Application Support，不会由本应用上传到其他服务。")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let statusMessage {
                Label(statusMessage, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(statusMessage)
            }

            Spacer(minLength: 16)

            Button("重新加载") {
                reloadFromDisk()
            }
            .disabled(isSaving)
            .help("重新加载本地配置文件")

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isSaving ? "正在保存" : "保存并刷新")
                }
                .frame(minWidth: 86)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func settingsField<Content: View>(
        _ title: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .font(.callout)
    }

    private func isPlatformConfigured(_ platform: SettingsPlatform) -> Bool {
        switch platform {
        case .cliproxyapi:
            return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .sub2api:
            return !sub2APIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !sub2APIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func loadFromStore() {
        baseURL = store.configuration.baseURL
        managementKey = store.configuration.managementKey
        sub2APIBaseURL = store.configuration.sub2APIBaseURL
        sub2APIKey = store.configuration.sub2APIKey
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

        let configuration = AppConfiguration(
            baseURL: baseURL,
            managementKey: managementKey,
            sub2APIBaseURL: sub2APIBaseURL,
            sub2APIKey: sub2APIKey,
            refreshIntervalSeconds: max(refreshIntervalSeconds, minimumRefreshSeconds)
        )

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
