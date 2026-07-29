import SwiftUI

@main
struct AgentStatusApp: App {
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

        Settings {
            SettingsView(store: store)
        }
    }
}
