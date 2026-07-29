import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: QuotaStore

    @State private var baseURL: String = ""
    @State private var managementKey: String = ""
    @State private var refreshIntervalSeconds: Int = AppConfiguration.defaultRefreshIntervalSeconds
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section("CLIProxyAPI") {
                TextField("Base URL", text: $baseURL, prompt: Text("https://example.com"))
                    .textFieldStyle(.roundedBorder)

                SecureField("Management Key", text: $managementKey)
                    .textFieldStyle(.roundedBorder)

                Stepper(value: $refreshIntervalSeconds, in: 30...3600, step: 30) {
                    Text("自动刷新 \(refreshIntervalSeconds) 秒")
                }
            }

            Section {
                HStack {
                    Button("保存并刷新") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("重新加载本地配置") {
                        reloadFromDisk()
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(isError ? .red : .secondary)
                }
            }

            Section("配置文件") {
                Text(AppConfigurationStore.configURL.path)
                    .font(.system(size: 11).monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 320)
        .onAppear(perform: loadFromStore)
    }

    private func loadFromStore() {
        baseURL = store.configuration.baseURL
        managementKey = store.configuration.managementKey
        refreshIntervalSeconds = max(store.configuration.refreshIntervalSeconds, 30)
    }

    private func reloadFromDisk() {
        store.reloadConfigurationFromDisk()
        loadFromStore()
        statusMessage = "已从本地配置重新加载"
        isError = false
    }

    private func save() {
        var configuration = AppConfiguration(
            baseURL: baseURL,
            managementKey: managementKey,
            refreshIntervalSeconds: refreshIntervalSeconds
        )
        if configuration.refreshIntervalSeconds <= 0 {
            configuration.refreshIntervalSeconds = AppConfiguration.defaultRefreshIntervalSeconds
        }

        do {
            try store.updateConfiguration(configuration)
            statusMessage = "已保存到 Application Support 并开始刷新"
            isError = false
        } catch {
            statusMessage = error.localizedDescription
            isError = true
        }
    }
}
