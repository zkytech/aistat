import AppKit
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
            Label {
                Text(store.menuTitle)
            } icon: {
                Image(nsImage: Self.menuBarIcon)
            }
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

    private static let menuBarIcon: NSImage = {
        let fallback = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: "Agent Status"
        ) ?? NSImage()

        // Prefer the 36px asset displayed at 18pt as a template image.
        for name in ["MenuBarIconTemplate@2x", "MenuBarIconTemplate"] {
            guard
                let url = Bundle.module.url(forResource: name, withExtension: "png"),
                let image = NSImage(contentsOf: url)
            else {
                continue
            }

            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        return fallback
    }()
}
