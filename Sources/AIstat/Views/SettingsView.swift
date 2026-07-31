import AppKit
import SwiftUI

// MARK: - Sidebar model

private enum SettingsAccountKind: String, CaseIterable, Identifiable {
    case cliproxyapi
    case sub2api
    case deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cliproxyapi: return "CLIProxyAPI"
        case .sub2api: return "Sub2API"
        case .deepseek: return "DeepSeek"
        }
    }

    var subtitle: String {
        switch self {
        case .cliproxyapi: return "Management API"
        case .sub2api: return "用量与余额"
        case .deepseek: return "官方余额"
        }
    }

    var iconResourceName: String {
        "PlatformIcon-\(rawValue)"
    }

    var fallbackSystemImage: String {
        switch self {
        case .cliproxyapi: return "server.rack"
        case .sub2api: return "arrow.triangle.2.circlepath.circle"
        case .deepseek: return "bolt.horizontal.circle"
        }
    }
}

private enum SettingsPane: Hashable {
    case cliProxy(String)
    case sub2(String)
    case deepSeek(String)
    case general
}

private struct PlatformIconView: View {
    let kind: SettingsAccountKind
    var size: CGFloat = 22
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Group {
            if let image = Self.loadImage(named: kind.iconResourceName, pointSize: size) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: kind.fallbackSystemImage)
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

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: QuotaStore

    @State private var selectedPane: SettingsPane = .general
    @State private var cliProxyConnections: [CLIProxyConnection] = []
    @State private var sub2APIConnections: [Sub2APIConnection] = []
    @State private var deepSeekConnections: [DeepSeekConnection] = []
    @State private var refreshIntervalSeconds: Int = AppConfiguration.defaultRefreshIntervalSeconds
    @State private var launchAtLoginEnabled: Bool = false
    @State private var launchAtLoginHint: String?
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isSaving = false
    @State private var showingAddSheet = false

    private let minimumRefreshSeconds = Int(QuotaStore.minimumRefreshInterval)

    var body: some View {
        HSplitView {
            settingsSidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)

            detailPane
                .frame(minWidth: 520)
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear(perform: loadFromStore)
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheet(
                existingCLIProxyCount: cliProxyConnections.count,
                existingSub2Count: sub2APIConnections.count,
                existingDeepSeekCount: deepSeekConnections.count
            ) { result in
                applyAddResult(result)
            }
        }
    }

    // MARK: Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader(title: "账号", subtitle: "每组连接一个标签")
                .padding(.top, 20)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(cliProxyConnections) { connection in
                        accountSidebarRow(
                            pane: .cliProxy(connection.id),
                            title: connection.displayName,
                            subtitle: SettingsAccountKind.cliproxyapi.subtitle,
                            configured: connection.isConfigured,
                            kind: .cliproxyapi
                        )
                    }
                    ForEach(sub2APIConnections) { connection in
                        accountSidebarRow(
                            pane: .sub2(connection.id),
                            title: connection.displayName,
                            subtitle: SettingsAccountKind.sub2api.subtitle,
                            configured: connection.isConfigured,
                            kind: .sub2api
                        )
                    }
                    ForEach(deepSeekConnections) { connection in
                        accountSidebarRow(
                            pane: .deepSeek(connection.id),
                            title: connection.displayName,
                            subtitle: SettingsAccountKind.deepseek.subtitle,
                            configured: connection.isConfigured,
                            kind: .deepseek
                        )
                    }

                    if cliProxyConnections.isEmpty && sub2APIConnections.isEmpty && deepSeekConnections.isEmpty {
                        Text("尚未添加账号")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }

                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("添加账号", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .help("添加 CLIProxyAPI 或 Sub2API 连接")
                }
            }

            sidebarSectionHeader(title: "应用", subtitle: "刷新与启动")
                .padding(.top, 16)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                sidebarRow(
                    selected: selectedPane == .general,
                    title: "通用",
                    subtitle: "刷新与开机启动"
                ) {
                    selectedPane = .general
                } icon: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

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

    private func accountSidebarRow(
        pane: SettingsPane,
        title: String,
        subtitle: String,
        configured: Bool,
        kind: SettingsAccountKind
    ) -> some View {
        sidebarRow(
            selected: selectedPane == pane,
            title: title,
            subtitle: subtitle,
            trailingConfigured: configured
        ) {
            selectedPane = pane
        } icon: {
            PlatformIconView(kind: kind, size: 28)
        }
        .padding(.horizontal, 10)
    }

    private func sidebarRow<Icon: View>(
        selected: Bool,
        title: String,
        subtitle: String,
        trailingConfigured: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon()

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    // MARK: Detail

    private var detailPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedPane {
                    case .cliProxy(let id):
                        if let index = cliProxyConnections.firstIndex(where: { $0.id == id }) {
                            cliProxyDetail(index: index)
                        } else {
                            missingAccountPlaceholder
                        }
                    case .sub2(let id):
                        if let index = sub2APIConnections.firstIndex(where: { $0.id == id }) {
                            sub2Detail(index: index)
                        } else {
                            missingAccountPlaceholder
                        }
                    case .deepSeek(let id):
                        if let index = deepSeekConnections.firstIndex(where: { $0.id == id }) {
                            deepSeekDetail(index: index)
                        } else {
                            missingAccountPlaceholder
                        }
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

    private var missingAccountPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("账号不存在")
                .font(.title2.weight(.semibold))
            Text("该连接可能已被删除，请从左侧重新选择或添加。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cliProxyDetail(index: Int) -> some View {
        let connection = cliProxyConnections[index]
        detailHeader(
            kind: .cliproxyapi,
            title: connection.displayName,
            description: "连接 CLIProxyAPI 管理端，读取 OpenAI / Claude / Grok 订阅额度。",
            configured: connection.isConfigured
        )

        settingsSection(title: "连接配置", subtitle: "名称会显示在菜单栏分组标题中。") {
            settingsField("名称", hint: "菜单栏分组与小组件选择列表") {
                TextField("例如：家里 / 公司", text: bindingCLIProxy(index).name)
                    .textFieldStyle(.roundedBorder)
            }
            settingsField("Base URL", hint: "CLIProxyAPI 管理服务地址") {
                TextField("https://127.0.0.1:8317", text: bindingCLIProxy(index).baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            settingsField("Management Key", hint: "用于访问 Management API") {
                SecureField("仅保存在本机", text: bindingCLIProxy(index).managementKey)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle(isOn: bindingCLIProxy(index).preferNearRefreshAccounts) {
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

        settingsSection(title: "说明", subtitle: "本连接在菜单栏中始终展示。") {
            infoRow(icon: "rectangle.split.3x1", text: "菜单栏按连接名称分组显示其下订阅账号。")
            infoRow(icon: "square.grid.2x2", text: "桌面小组件可在每个实例的编辑界面单独选择是否展示本连接。")
        }

        Button(role: .destructive) {
            deleteCLIProxy(id: connection.id)
        } label: {
            Label("删除此账号", systemImage: "trash")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func sub2Detail(index: Int) -> some View {
        let connection = sub2APIConnections[index]
        detailHeader(
            kind: .sub2api,
            title: connection.displayName,
            description: "连接 Sub2API，通过用量接口读取账户余额。",
            configured: connection.isConfigured
        )

        settingsSection(title: "连接配置", subtitle: "名称会显示在余额前。") {
            settingsField("名称", hint: "显示在余额前缀") {
                TextField("例如：主账户 / 备用", text: bindingSub2(index).name)
                    .textFieldStyle(.roundedBorder)
            }
            settingsField("Base URL", hint: "Sub2API 服务地址") {
                TextField("https://aihub.top", text: bindingSub2(index).baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            settingsField("API Key", hint: "作为 Bearer Token 发送") {
                SecureField("仅保存在本机", text: bindingSub2(index).apiKey)
                    .textFieldStyle(.roundedBorder)
            }
        }

        settingsSection(title: "说明", subtitle: "本连接在菜单栏中始终展示。") {
            infoRow(icon: "creditcard", text: "菜单栏余额前缀为连接名称。")
            infoRow(icon: "square.grid.2x2", text: "桌面小组件可在每个实例的编辑界面单独选择是否展示本连接。")
        }

        Button(role: .destructive) {
            deleteSub2(id: connection.id)
        } label: {
            Label("删除此账号", systemImage: "trash")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func deepSeekDetail(index: Int) -> some View {
        let connection = deepSeekConnections[index]
        detailHeader(
            kind: .deepseek,
            title: connection.displayName,
            description: "连接 DeepSeek 官方余额接口，读取账户可用余额。",
            configured: connection.isConfigured
        )

        settingsSection(title: "连接配置", subtitle: "名称会显示在余额前。") {
            settingsField("名称", hint: "显示在余额前缀") {
                TextField("例如：主账户 / 备用", text: bindingDeepSeek(index).name)
                    .textFieldStyle(.roundedBorder)
            }
            settingsField("API Key", hint: "作为 Bearer Token 发送") {
                SecureField("仅保存在本机", text: bindingDeepSeek(index).apiKey)
                    .textFieldStyle(.roundedBorder)
            }
        }

        settingsSection(title: "说明", subtitle: "本连接在菜单栏中始终展示。") {
            infoRow(icon: "creditcard", text: "菜单栏余额前缀为连接名称。")
            infoRow(icon: "server.rack", text: "使用 DeepSeek 官方余额接口（https://api.deepseek.com/user/balance），无需填写 Base URL。")
            infoRow(icon: "square.grid.2x2", text: "桌面小组件可在每个实例的编辑界面单独选择是否展示本连接。")
        }

        Button(role: .destructive) {
            deleteDeepSeek(id: connection.id)
        } label: {
            Label("删除此账号", systemImage: "trash")
        }
        .buttonStyle(.borderless)
    }

    private func detailHeader(
        kind: SettingsAccountKind,
        title: String,
        description: String,
        configured: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PlatformIconView(kind: kind, size: 44, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Label(
                        configured ? "已配置" : "未配置",
                        systemImage: configured ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(configured ? Color.green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                Text(kind.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generalDetail: some View {
        Group {
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
                    Text("自动刷新、开机启动与本地配置文件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

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

            settingsSection(title: "启动", subtitle: "由系统登录项管理，与数据源无关。") {
                Toggle(isOn: launchAtLoginBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动")
                        Text("登录 macOS 后自动在后台启动菜单栏应用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if let launchAtLoginHint {
                    Label(launchAtLoginHint, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection(title: "桌面小组件", subtitle: "展示源在每个小组件实例上单独配置。") {
                infoRow(
                    icon: "square.grid.2x2",
                    text: "在桌面或通知中心长按 / 编辑小组件，选择要展示的 CLIProxyAPI 与 Sub2API 账号。"
                )
                infoRow(
                    icon: "menubar.rectangle",
                    text: "菜单栏始终显示全部账号，无需额外勾选。"
                )
            }

            settingsSection(title: "配置文件", subtitle: "所有连接保存在同一个本地配置文件中。") {
                Text(AppConfigurationStore.configURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Divider()
                infoRow(icon: "lock", text: "访问凭据仅写入 Application Support，不会由本应用上传到其他服务。")
            }
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let statusMessage {
                Label(statusMessage, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 16)

            Button("重新加载") {
                reloadFromDisk()
            }
            .disabled(isSaving)

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

    // MARK: Form helpers

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

    private func bindingCLIProxy(_ index: Int) -> Binding<CLIProxyConnection> {
        Binding(
            get: { cliProxyConnections[index] },
            set: { cliProxyConnections[index] = $0 }
        )
    }

    private func bindingSub2(_ index: Int) -> Binding<Sub2APIConnection> {
        Binding(
            get: { sub2APIConnections[index] },
            set: { sub2APIConnections[index] = $0 }
        )
    }

    private func bindingDeepSeek(_ index: Int) -> Binding<DeepSeekConnection> {
        Binding(
            get: { deepSeekConnections[index] },
            set: { deepSeekConnections[index] = $0 }
        )
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

    // MARK: Mutations

    private func applyAddResult(_ result: AddAccountResult) {
        switch result {
        case .cliProxy(let connection):
            cliProxyConnections.append(connection)
            selectedPane = .cliProxy(connection.id)
            statusMessage = "已添加 \(connection.displayName)，请填写完整后保存"
            isError = false
        case .sub2(let connection):
            sub2APIConnections.append(connection)
            selectedPane = .sub2(connection.id)
            statusMessage = "已添加 \(connection.displayName)，请填写完整后保存"
            isError = false
        case .deepSeek(let connection):
            deepSeekConnections.append(connection)
            selectedPane = .deepSeek(connection.id)
            statusMessage = "已添加 \(connection.displayName)，请填写完整后保存"
            isError = false
        }
    }

    private func deleteCLIProxy(id: String) {
        cliProxyConnections.removeAll { $0.id == id }
        if case .cliProxy(let selected) = selectedPane, selected == id {
            selectFallbackPane()
        }
        statusMessage = "已从列表移除，点击「保存并刷新」写入配置"
        isError = false
    }

    private func deleteSub2(id: String) {
        sub2APIConnections.removeAll { $0.id == id }
        if case .sub2(let selected) = selectedPane, selected == id {
            selectFallbackPane()
        }
        statusMessage = "已从列表移除，点击「保存并刷新」写入配置"
        isError = false
    }

    private func deleteDeepSeek(id: String) {
        deepSeekConnections.removeAll { $0.id == id }
        if case .deepSeek(let selected) = selectedPane, selected == id {
            selectFallbackPane()
        }
        statusMessage = "已从列表移除，点击「保存并刷新」写入配置"
        isError = false
    }

    private func selectFallbackPane() {
        if let first = cliProxyConnections.first {
            selectedPane = .cliProxy(first.id)
        } else if let first = sub2APIConnections.first {
            selectedPane = .sub2(first.id)
        } else if let first = deepSeekConnections.first {
            selectedPane = .deepSeek(first.id)
        } else {
            selectedPane = .general
        }
    }

    private func loadFromStore() {
        cliProxyConnections = store.configuration.cliProxyConnections
        sub2APIConnections = store.configuration.sub2APIConnections
        deepSeekConnections = store.configuration.deepSeekConnections
        refreshIntervalSeconds = max(store.configuration.refreshIntervalSeconds, minimumRefreshSeconds)
        syncLaunchAtLoginFromSystem()

        // Prefer first account tab when opening settings with existing connections.
        if case .general = selectedPane {
            if let first = cliProxyConnections.first {
                selectedPane = .cliProxy(first.id)
            } else if let first = sub2APIConnections.first {
                selectedPane = .sub2(first.id)
            } else if let first = deepSeekConnections.first {
                selectedPane = .deepSeek(first.id)
            }
        } else {
            ensureSelectedPaneExists()
        }
    }

    private func ensureSelectedPaneExists() {
        switch selectedPane {
        case .cliProxy(let id):
            if !cliProxyConnections.contains(where: { $0.id == id }) {
                selectFallbackPane()
            }
        case .sub2(let id):
            if !sub2APIConnections.contains(where: { $0.id == id }) {
                selectFallbackPane()
            }
        case .deepSeek(let id):
            if !deepSeekConnections.contains(where: { $0.id == id }) {
                selectFallbackPane()
            }
        case .general:
            break
        }
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

        let configuration = AppConfiguration(
            cliProxyConnections: cliProxyConnections,
            sub2APIConnections: sub2APIConnections,
            deepSeekConnections: deepSeekConnections,
            refreshIntervalSeconds: max(refreshIntervalSeconds, minimumRefreshSeconds)
        )

        do {
            try store.updateConfiguration(configuration)
            loadFromStore()
            statusMessage = "已保存到 Application Support 并开始刷新"
            isError = false
        } catch {
            statusMessage = error.localizedDescription
            isError = true
        }
    }
}

// MARK: - Add account sheet

private enum AddAccountResult {
    case cliProxy(CLIProxyConnection)
    case sub2(Sub2APIConnection)
    case deepSeek(DeepSeekConnection)
}

private struct AddAccountSheet: View {
    let existingCLIProxyCount: Int
    let existingSub2Count: Int
    let existingDeepSeekCount: Int
    let onComplete: (AddAccountResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: SettingsAccountKind = .cliproxyapi
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var credential: String = ""
    @State private var preferNearRefreshAccounts = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加账号")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    Picker("账号类型", selection: $kind) {
                        ForEach(SettingsAccountKind.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) {
                        applyDefaultNameIfNeeded()
                    }
                }

                Section {
                    TextField("名称", text: $name)
                    if kind != .deepseek {
                        TextField("Base URL", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    if kind == .cliproxyapi {
                        SecureField("Management Key", text: $credential)
                        Toggle("优先消耗即将刷新额度的账号", isOn: $preferNearRefreshAccounts)
                    } else {
                        SecureField("API Key", text: $credential)
                    }
                } header: {
                    Text(connectionHeader)
                } footer: {
                    Text(kind == .cliproxyapi
                         ? "名称用于菜单栏分组；密钥仅保存在本机。"
                         : "名称会显示在余额前；密钥仅保存在本机。")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("添加") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .onAppear {
            applyDefaultNameIfNeeded(force: true)
        }
    }

    private var connectionHeader: String {
        switch kind {
        case .cliproxyapi: return "CLIProxyAPI 连接"
        case .sub2api: return "Sub2API 连接"
        case .deepseek: return "DeepSeek 连接"
        }
    }

    private var canCommit: Bool {
        if kind == .deepseek {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyDefaultNameIfNeeded(force: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || trimmed.isEmpty || trimmed.hasPrefix("CLIProxy") || trimmed.hasPrefix("Sub2API")
                || trimmed.hasPrefix("DeepSeek") || trimmed == "默认" else {
            return
        }
        switch kind {
        case .cliproxyapi:
            let index = existingCLIProxyCount + 1
            name = index == 1 ? "默认" : "CLIProxy \(index)"
        case .sub2api:
            let index = existingSub2Count + 1
            name = index == 1 ? "默认" : "Sub2API \(index)"
        case .deepseek:
            let index = existingDeepSeekCount + 1
            name = index == 1 ? "默认" : "DeepSeek \(index)"
        }
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .cliproxyapi:
            let connection = CLIProxyConnection(
                name: trimmedName,
                baseURL: baseURL,
                managementKey: credential,
                preferNearRefreshAccounts: preferNearRefreshAccounts
            )
            onComplete(.cliProxy(connection))
        case .sub2api:
            let connection = Sub2APIConnection(
                name: trimmedName,
                baseURL: baseURL,
                apiKey: credential
            )
            onComplete(.sub2(connection))
        case .deepseek:
            let connection = DeepSeekConnection(
                name: trimmedName,
                apiKey: credential
            )
            onComplete(.deepSeek(connection))
        }
        dismiss()
    }
}
