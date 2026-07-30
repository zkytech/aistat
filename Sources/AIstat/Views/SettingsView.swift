import AppKit
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
            return "可添加多组 CLIProxyAPI 管理端；菜单栏按连接名称分组显示订阅账号。"
        case .sub2api:
            return "可添加多组 Sub2API 账号；余额前会显示连接名称。"
        }
    }

    /// Resource name under `Resources/PlatformIcon-*.png` (official brand marks).
    var iconResourceName: String {
        "PlatformIcon-\(rawValue)"
    }

    var fallbackSystemImage: String {
        switch self {
        case .cliproxyapi: return "server.rack"
        case .sub2api: return "arrow.triangle.2.circlepath.circle"
        }
    }
}

private enum SettingsPane: Hashable {
    case platform(SettingsPlatform)
    case general

    var title: String {
        switch self {
        case .platform(let platform): return platform.title
        case .general: return "通用"
        }
    }
}

/// Colored brand icon for settings data sources (CLIProxyAPI / Sub2API).
private struct PlatformIconView: View {
    let platform: SettingsPlatform
    var size: CGFloat = 22
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Group {
            if let image = Self.loadImage(named: platform.iconResourceName, pointSize: size) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: platform.fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.22
    }

    private static func loadImage(named name: String, pointSize: CGFloat) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}

struct SettingsView: View {
    @ObservedObject var store: QuotaStore

    @State private var selectedPane: SettingsPane = .platform(.cliproxyapi)
    @State private var cliProxyConnections: [CLIProxyConnection] = []
    @State private var sub2APIConnections: [Sub2APIConnection] = []
    @State private var widgetCLIProxyConnectionIDs: Set<String> = []
    @State private var widgetSub2APIConnectionIDs: Set<String> = []
    @State private var refreshIntervalSeconds: Int = AppConfiguration.defaultRefreshIntervalSeconds
    @State private var launchAtLoginEnabled: Bool = false
    @State private var launchAtLoginHint: String?
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isSaving = false

    private let minimumRefreshSeconds = Int(QuotaStore.minimumRefreshInterval)

    var body: some View {
        HSplitView {
            settingsSidebar
                .frame(minWidth: 210, idealWidth: 220, maxWidth: 240)

            detailPane
                .frame(minWidth: 520)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear(perform: loadFromStore)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader(title: "数据源", subtitle: "选择要配置的服务")
                .padding(.top, 20)
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                ForEach(SettingsPlatform.allCases) { platform in
                    sidebarRow(
                        pane: .platform(platform),
                        title: platform.title,
                        subtitle: platform.subtitle,
                        trailingConfigured: isPlatformConfigured(platform)
                    ) {
                        PlatformIconView(platform: platform, size: 28)
                    }
                }
            }
            .padding(.horizontal, 10)

            sidebarSectionHeader(title: "应用", subtitle: "与数据源无关的选项")
                .padding(.top, 22)
                .padding(.bottom, 10)

            VStack(spacing: 6) {
                sidebarRow(
                    pane: .general,
                    title: "通用",
                    subtitle: "刷新与小组件"
                ) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                        .accessibilityHidden(true)
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

    private func sidebarSectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func sidebarRow<Icon: View>(
        pane: SettingsPane,
        title: String,
        subtitle: String,
        trailingConfigured: Bool = false,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let selected = selectedPane == pane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 12) {
                icon()

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if trailingConfigured {
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
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedPane {
                    case .platform(let platform):
                        platformDetail(platform)
                    case .general:
                        generalDetail
                    }
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

    @ViewBuilder
    private func platformDetail(_ platform: SettingsPlatform) -> some View {
        platformHeader(platform)
        connectionsSection(for: platform)
        dataSourceNotesSection(for: platform)
    }

    private var generalDetail: some View {
        Group {
            generalHeader
            refreshSection
            widgetSelectionSection
            launchAtLoginSection
            configurationFileSection
        }
    }

    private func platformHeader(_ platform: SettingsPlatform) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PlatformIconView(platform: platform, size: 44, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(platform.title)
                        .font(.title2.weight(.semibold))
                    configurationStatus(for: platform)
                }
                Text(platform.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generalHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("通用")
                    .font(.title2.weight(.semibold))
                Text("自动刷新、小组件数据源、开机启动与本地配置文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func configurationStatus(for platform: SettingsPlatform) -> some View {
        let count = configuredConnectionCount(platform)
        let label: String
        if count == 0 {
            label = "未配置"
        } else {
            label = "\(count) 组已配置"
        }
        return Label(label, systemImage: count > 0 ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.medium))
            .foregroundStyle(count > 0 ? Color.green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    @ViewBuilder
    private func connectionsSection(for platform: SettingsPlatform) -> some View {
        settingsSection(
            title: "连接账号",
            subtitle: "每组可单独命名；菜单栏与小组件按名称区分。"
        ) {
            switch platform {
            case .cliproxyapi:
                if cliProxyConnections.isEmpty {
                    emptyConnectionsHint("尚未添加 CLIProxyAPI 连接")
                }
                ForEach($cliProxyConnections) { $connection in
                    cliProxyConnectionEditor(connection: $connection)
                }
                Button {
                    cliProxyConnections.append(
                        CLIProxyConnection(name: defaultCLIProxyName())
                    )
                } label: {
                    Label("添加 CLIProxyAPI 账号", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            case .sub2api:
                if sub2APIConnections.isEmpty {
                    emptyConnectionsHint("尚未添加 Sub2API 连接")
                }
                ForEach($sub2APIConnections) { $connection in
                    sub2APIConnectionEditor(connection: $connection)
                }
                Button {
                    sub2APIConnections.append(
                        Sub2APIConnection(name: defaultSub2APIName())
                    )
                } label: {
                    Label("添加 Sub2API 账号", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func emptyConnectionsHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cliProxyConnectionEditor(connection: Binding<CLIProxyConnection>) -> some View {
        let id = connection.wrappedValue.id
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(connection.wrappedValue.displayName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if connection.wrappedValue.isConfigured {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button(role: .destructive) {
                        removeCLIProxyConnection(id: id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除此连接")
                }

                settingsField("名称", hint: "用于菜单栏分组与小组件选择") {
                    TextField("例如：家里 / 公司", text: connection.name)
                        .textFieldStyle(.roundedBorder)
                }
                settingsField("Base URL", hint: "CLIProxyAPI 管理服务地址") {
                    TextField("https://127.0.0.1:8317", text: connection.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                settingsField("Management Key", hint: "用于访问 Management API") {
                    SecureField("仅保存在本机", text: connection.managementKey)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle(isOn: connection.preferNearRefreshAccounts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("优先消耗即将刷新额度的账号")
                        Text("仅对本连接生效：按周额度重置时间排序，并同步该 CLIProxyAPI 的 priority。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(4)
        }
    }

    private func sub2APIConnectionEditor(connection: Binding<Sub2APIConnection>) -> some View {
        let id = connection.wrappedValue.id
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(connection.wrappedValue.displayName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if connection.wrappedValue.isConfigured {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button(role: .destructive) {
                        removeSub2APIConnection(id: id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除此连接")
                }

                settingsField("名称", hint: "显示在余额前") {
                    TextField("例如：主账户 / 备用", text: connection.name)
                        .textFieldStyle(.roundedBorder)
                }
                settingsField("Base URL", hint: "Sub2API 服务地址") {
                    TextField("https://aihub.top", text: connection.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                settingsField("API Key", hint: "作为 Bearer Token 发送") {
                    SecureField("仅保存在本机", text: connection.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func dataSourceNotesSection(for platform: SettingsPlatform) -> some View {
        settingsSection(title: "数据来源", subtitle: "当前数据源使用的接口与范围。") {
            switch platform {
            case .cliproxyapi:
                infoRow(icon: "person.2", text: "从 Management API 获取 xAI / OpenAI / Claude 账号列表。")
                infoRow(icon: "chart.bar", text: "逐账号读取周额度；可用时同时读取月度额度。")
                infoRow(icon: "rectangle.split.3x1", text: "多组连接在菜单栏按连接名称分组显示。")
            case .sub2api:
                infoRow(icon: "chart.bar", text: "从 GET /v1/usage 读取账户用量和余额。")
                infoRow(icon: "key", text: "请求使用 Authorization: Bearer <API Key>。")
                infoRow(icon: "tag", text: "多组余额前缀为各自的连接名称。")
            }
        }
    }

    private var refreshSection: some View {
        settingsSection(title: "自动刷新", subtitle: "所有数据源共用同一刷新间隔。") {
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

    private var widgetSelectionSection: some View {
        settingsSection(
            title: "桌面小组件",
            subtitle: "必须手动勾选要展示的连接；多选时按连接列表顺序与组内默认排序展示。"
        ) {
            if cliProxyConnections.isEmpty && sub2APIConnections.isEmpty {
                Text("请先在左侧添加 CLIProxyAPI 或 Sub2API 连接。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if !cliProxyConnections.isEmpty {
                    Text("CLIProxyAPI")
                        .font(.subheadline.weight(.medium))
                    ForEach(cliProxyConnections) { connection in
                        Toggle(isOn: widgetCLIBinding(for: connection.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.displayName)
                                Text(connection.isConfigured ? connection.normalizedBaseURL : "未配置完整")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!connection.isConfigured)
                    }
                }

                if !sub2APIConnections.isEmpty {
                    if !cliProxyConnections.isEmpty {
                        Divider()
                    }
                    Text("Sub2API")
                        .font(.subheadline.weight(.medium))
                    ForEach(sub2APIConnections) { connection in
                        Toggle(isOn: widgetSub2Binding(for: connection.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.displayName)
                                Text(connection.isConfigured ? connection.normalizedBaseURL : "未配置完整")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!connection.isConfigured)
                    }
                }
            }
        }
    }

    private func widgetCLIBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { widgetCLIProxyConnectionIDs.contains(id) },
            set: { selected in
                if selected {
                    widgetCLIProxyConnectionIDs.insert(id)
                } else {
                    widgetCLIProxyConnectionIDs.remove(id)
                }
            }
        )
    }

    private func widgetSub2Binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { widgetSub2APIConnectionIDs.contains(id) },
            set: { selected in
                if selected {
                    widgetSub2APIConnectionIDs.insert(id)
                } else {
                    widgetSub2APIConnectionIDs.remove(id)
                }
            }
        )
    }

    private var launchAtLoginSection: some View {
        settingsSection(title: "启动", subtitle: "由系统登录项管理，与数据源无关。") {
            Toggle(isOn: launchAtLoginBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开机自动启动")
                    Text("登录 macOS 后自动在后台启动菜单栏应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel("开机自动启动")

            if let launchAtLoginHint {
                Label(launchAtLoginHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLoginService.setEnabled(newValue)
                    syncLaunchAtLoginFromSystem()
                    if launchAtLoginHint == nil {
                        statusMessage = newValue ? "已开启开机自动启动" : "已关闭开机自动启动"
                        isError = false
                    }
                } catch {
                    syncLaunchAtLoginFromSystem()
                    statusMessage = error.localizedDescription
                    isError = true
                }
            }
        )
    }

    private var configurationFileSection: some View {
        settingsSection(title: "配置文件", subtitle: "所有连接保存在同一个本地配置文件中。") {
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
        configuredConnectionCount(platform) > 0
    }

    private func configuredConnectionCount(_ platform: SettingsPlatform) -> Int {
        switch platform {
        case .cliproxyapi:
            return cliProxyConnections.filter(\.isConfigured).count
        case .sub2api:
            return sub2APIConnections.filter(\.isConfigured).count
        }
    }

    private func defaultCLIProxyName() -> String {
        let index = cliProxyConnections.count + 1
        return index == 1 ? "默认" : "CLIProxy \(index)"
    }

    private func defaultSub2APIName() -> String {
        let index = sub2APIConnections.count + 1
        return index == 1 ? "默认" : "Sub2API \(index)"
    }

    private func removeCLIProxyConnection(id: String) {
        cliProxyConnections.removeAll { $0.id == id }
        widgetCLIProxyConnectionIDs.remove(id)
    }

    private func removeSub2APIConnection(id: String) {
        sub2APIConnections.removeAll { $0.id == id }
        widgetSub2APIConnectionIDs.remove(id)
    }

    private func loadFromStore() {
        cliProxyConnections = store.configuration.cliProxyConnections
        sub2APIConnections = store.configuration.sub2APIConnections
        widgetCLIProxyConnectionIDs = Set(store.configuration.widgetCLIProxyConnectionIDs)
        widgetSub2APIConnectionIDs = Set(store.configuration.widgetSub2APIConnectionIDs)
        refreshIntervalSeconds = max(store.configuration.refreshIntervalSeconds, minimumRefreshSeconds)
        syncLaunchAtLoginFromSystem()
    }

    private func syncLaunchAtLoginFromSystem() {
        launchAtLoginEnabled = LaunchAtLoginService.isEnabled
        launchAtLoginHint = LaunchAtLoginService.statusHint
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
            cliProxyConnections: cliProxyConnections,
            sub2APIConnections: sub2APIConnections,
            refreshIntervalSeconds: max(refreshIntervalSeconds, minimumRefreshSeconds),
            widgetCLIProxyConnectionIDs: Array(widgetCLIProxyConnectionIDs),
            widgetSub2APIConnectionIDs: Array(widgetSub2APIConnectionIDs)
        )
        configuration.pruneWidgetSelection()

        do {
            try store.updateConfiguration(configuration)
            // Reload local editor state with pruned selection / normalized values.
            loadFromStore()
            statusMessage = "已保存到 Application Support 并开始刷新"
            isError = false
        } catch {
            statusMessage = error.localizedDescription
            isError = true
        }
    }
}
