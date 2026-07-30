import AppKit

/// Owns the shared `QuotaStore` and starts refresh as soon as the process launches,
/// so WidgetKit snapshots update without opening the menu bar panel.
@MainActor
final class AIstatAppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
