import AppKit
import SwiftUI

@main
struct AIstatApp: App {
    static let settingsWindowID = "settings"

    @NSApplicationDelegateAdaptor(AIstatAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: appDelegate.store)
                .onAppear {
                    appDelegate.store.start()
                }
        } label: {
            // Observe store so the menu title stays live.
            MenuBarLabelView(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: Self.settingsWindowID) {
            SettingsView(store: appDelegate.store)
        }
        .defaultSize(width: 820, height: 620)

        // Keep system Settings entry as a secondary path.
        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}

/// Isolates `@ObservedObject` so the menu bar title refreshes with quota changes.
private struct MenuBarLabelView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        Label {
            Text(store.menuTitle)
        } icon: {
            Image(nsImage: AIstatApp.menuBarIcon)
        }
    }
}

extension AIstatApp {
    static let menuBarIcon: NSImage = {
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
