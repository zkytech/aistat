import AppKit
import SwiftUI

@main
struct AIstatApp: App {
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
        .defaultSize(width: 820, height: 620)

        // Keep system Settings entry as a secondary path.
        Settings {
            SettingsView(store: store)
        }
    }

    private static let menuBarIcon: NSImage = {
        let fallback = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: "AIstat"
        ) ?? NSImage()

        // Prefer the 36px asset displayed at 18pt as a template image.
        // Packaged .app: Contents/Resources/*.png via Bundle.main
        // `swift run`: SPM resource bundle via Bundle.module
        for name in ["MenuBarIconTemplate@2x", "MenuBarIconTemplate"] {
            guard
                let url = menuBarIconURL(named: name),
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

    private static func menuBarIconURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: "png")
    }
}
