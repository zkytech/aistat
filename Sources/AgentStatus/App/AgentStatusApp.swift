import SwiftUI

@main
struct AgentStatusApp: App {
    static let settingsWindowID = "settings"

    @StateObject private var store = QuotaStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
                .onAppear {
                    store.start()
                }
        } label: {
            Label(store.menuTitle, systemImage: "chart.bar.fill")
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: Self.settingsWindowID) {
            SettingsView(store: store)
        }
        .defaultSize(width: 640, height: 460)

        // Keep system Settings entry as a secondary path.
        Settings {
            SettingsView(store: store)
        }
    }
}
