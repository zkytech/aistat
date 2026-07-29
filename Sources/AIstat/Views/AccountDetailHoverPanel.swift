import AppKit
import SwiftUI

/// Independent non-activating panel that hosts the account detail card to the
/// left of the MenuBarExtra window without resizing the main panel.
@MainActor
final class AccountDetailHoverPanelController {
    private var panel: NSPanel?
    private var materialView: NSVisualEffectView?
    private var hostingView: NSHostingView<AccountDetailHoverPanelContent>?
    private var currentItemID: String?
    private weak var trackedAnchorWindow: NSWindow?
    private var anchorObservations: [NSObjectProtocol] = []
    private var pointerPollTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?
    private var onDismiss: (() -> Void)?

    private let horizontalGap: CGFloat = 8
    private let screenInset: CGFloat = 8
    private let dismissGrace: TimeInterval = 0.18
    /// Matches MenuBarExtra `.window` continuous corner radius on macOS 13+.
    private let panelCornerRadius: CGFloat = 12

    deinit {
        for observation in anchorObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        pointerPollTimer?.invalidate()
    }

    func show(
        item: AccountQuota,
        relativeTo anchorWindow: NSWindow?,
        onDismiss: @escaping () -> Void
    ) {
        guard let anchorWindow else {
            hide()
            return
        }

        self.onDismiss = onDismiss
        trackAnchorWindow(anchorWindow)

        let panel = ensurePanel()
        let sameVisibleItem = isVisible && currentItemID == item.id
        let content = AccountDetailHoverPanelContent(item: item)

        if let hostingView {
            // Same account still visible: keep the existing view tree.
            if !(sameVisibleItem && hostingView.rootView.item == item) {
                hostingView.rootView = content
            }
        } else {
            let material = makeMaterialView()
            let host = NSHostingView(rootView: content)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.autoresizingMask = [.width, .height]
            host.frame = material.bounds
            material.addSubview(host)
            panel.contentView = material
            materialView = material
            hostingView = host
        }

        // Keep glass chrome in sync with the MenuBarExtra window whenever shown.
        syncMaterialChrome(with: anchorWindow)

        currentItemID = item.id
        panel.layoutIfNeeded()
        let size = preferredSize(for: hostingView)

        if !sameVisibleItem || panel.frame.size != size {
            panel.setContentSize(size)
            hostingView?.frame = NSRect(origin: .zero, size: size)
            materialView?.frame = NSRect(origin: .zero, size: size)
        }

        position(panel: panel, size: size, relativeTo: anchorWindow)
        startPointerPollingIfNeeded()

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func updatePosition(relativeTo anchorWindow: NSWindow?) {
        guard let panel, panel.isVisible else { return }
        guard let anchorWindow else {
            hide()
            return
        }
        position(panel: panel, size: panel.frame.size, relativeTo: anchorWindow)
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentItemID = nil
        onDismiss = nil
        clearAnchorTracking()
        stopPointerPolling()
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        // Transparent title-less window so material can blur the desktop like MenuBarExtra.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        self.panel = panel
        return panel
    }

    private func makeMaterialView() -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 320))
        view.autoresizingMask = [.width, .height]
        applyDefaultMaterial(to: view)
        view.wantsLayer = true
        view.layer?.cornerRadius = panelCornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    /// Prefer the live MenuBarExtra glass settings; fall back to public popover material.
    private func syncMaterialChrome(with anchorWindow: NSWindow?) {
        guard let materialView else { return }

        if let source = firstVisualEffectView(in: anchorWindow?.contentView) {
            materialView.material = source.material
            materialView.blendingMode = source.blendingMode
            materialView.state = .active
            materialView.isEmphasized = source.isEmphasized
        } else {
            applyDefaultMaterial(to: materialView)
        }

        // Match appearance (light/dark + accent vibrancy) of the main panel.
        let appearance = anchorWindow?.effectiveAppearance
        materialView.appearance = appearance
        panel?.appearance = appearance
        materialView.layer?.cornerRadius = panelCornerRadius
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
    }

    private func applyDefaultMaterial(to view: NSVisualEffectView) {
        // Closest public material to MenuBarExtra `.window` chrome when the
        // source effect view is not yet available.
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
    }

    private func firstVisualEffectView(in root: NSView?) -> NSVisualEffectView? {
        guard let root else { return nil }
        if let effect = root as? NSVisualEffectView {
            return effect
        }
        for subview in root.subviews {
            if let found = firstVisualEffectView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func preferredSize(for hostingView: NSHostingView<AccountDetailHoverPanelContent>?) -> NSSize {
        guard let hostingView else {
            return NSSize(width: 300, height: 320)
        }

        hostingView.invalidateIntrinsicContentSize()
        var size = hostingView.fittingSize
        if size.width < 1 {
            size.width = 300
        }
        if size.height < 1 {
            size.height = 320
        }
        size.width = min(max(size.width, 280), 340)
        // Grow with content (no internal scrollbar); only clamp to the visible screen.
        let screenHeight = (trackedAnchorWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maxHeight = max(screenHeight - screenInset * 2, 160)
        size.height = min(max(size.height, 160), maxHeight)
        return size
    }

    private func position(panel: NSPanel, size: NSSize, relativeTo anchorWindow: NSWindow) {
        let anchorFrame = anchorWindow.frame
        let screenFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let preferredLeftX = anchorFrame.minX - horizontalGap - size.width
        let preferredRightX = anchorFrame.maxX + horizontalGap
        let minX = screenFrame.minX + screenInset
        let maxX = screenFrame.maxX - screenInset - size.width

        let originX: CGFloat
        if preferredLeftX >= minX {
            originX = preferredLeftX
        } else if preferredRightX <= maxX {
            originX = preferredRightX
        } else {
            originX = min(max(preferredLeftX, minX), maxX)
        }

        var originY = anchorFrame.maxY - size.height
        let minY = screenFrame.minY + screenInset
        let maxY = screenFrame.maxY - screenInset - size.height
        if maxY >= minY {
            originY = min(max(originY, minY), maxY)
        } else {
            originY = screenFrame.minY + screenInset
        }

        let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func trackAnchorWindow(_ window: NSWindow) {
        if trackedAnchorWindow === window {
            return
        }

        clearAnchorTracking()
        trackedAnchorWindow = window

        let center = NotificationCenter.default
        anchorObservations = [
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                // Capture object outside the Task so Notification (non-Sendable)
                // is not crossed into an async boundary under Swift 6.
                let closedWindow = notification.object as? NSWindow
                Task { @MainActor [weak self] in
                    guard let self, let closedWindow, closedWindow === self.trackedAnchorWindow else {
                        return
                    }
                    self.requestDismiss()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.trackedAnchorWindow?.isVisible != true {
                        self.requestDismiss()
                    }
                }
            },
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                let changedWindow = notification.object as? NSWindow
                Task { @MainActor [weak self] in
                    guard let self, let changedWindow, changedWindow === self.trackedAnchorWindow else {
                        return
                    }
                    if !changedWindow.isVisible || !changedWindow.occlusionState.contains(.visible) {
                        self.requestDismiss()
                    }
                }
            }
        ]
    }

    private func clearAnchorTracking() {
        for observation in anchorObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        anchorObservations.removeAll()
        trackedAnchorWindow = nil
    }

    private func startPointerPollingIfNeeded() {
        guard pointerPollTimer == nil else { return }
        // Polling is required because local mouse monitors stop receiving
        // events once the pointer leaves both windows, and global monitors
        // need Accessibility permission.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluatePointerLocation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerPollTimer = timer
    }

    private func stopPointerPolling() {
        pointerPollTimer?.invalidate()
        pointerPollTimer = nil
    }

    private func evaluatePointerLocation() {
        guard isVisible else {
            stopPointerPolling()
            return
        }

        // Anchor disappeared (MenuBarExtra closed) — drop the orphan card.
        if trackedAnchorWindow?.isVisible != true {
            requestDismiss()
            return
        }

        let pointer = NSEvent.mouseLocation
        let overMain = trackedAnchorWindow?.frame.contains(pointer) == true
        let overDetail = panel?.frame.contains(pointer) == true

        if overMain || overDetail {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            return
        }

        scheduleDismiss()
    }

    private func scheduleDismiss() {
        guard dismissWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pointer = NSEvent.mouseLocation
            let overMain = self.trackedAnchorWindow?.frame.contains(pointer) == true
            let overDetail = self.panel?.frame.contains(pointer) == true
            if !overMain && !overDetail {
                // Direct hide/clear — do not depend on SwiftUI onHover flags.
                self.requestDismiss()
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissGrace, execute: work)
    }

    private func requestDismiss() {
        let dismiss = onDismiss
        hide()
        dismiss?()
    }
}

private struct AccountDetailHoverPanelContent: View {
    let item: AccountQuota

    var body: some View {
        AccountQuotaDetailView(item: item)
    }
}

struct HostWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.emit(window)
        }
        DispatchQueue.main.async {
            context.coordinator.emit(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        if let view = nsView as? WindowObservingView {
            view.onWindowChange = { [weak coordinator = context.coordinator] window in
                coordinator?.emit(window)
            }
        }
        context.coordinator.emit(nsView.window)
    }

    final class Coordinator {
        var onChange: (NSWindow?) -> Void
        private weak var lastWindow: NSWindow?

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
        }

        func emit(_ window: NSWindow?) {
            if lastWindow === window {
                return
            }
            lastWindow = window
            onChange(window)
        }
    }
}

private final class WindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
