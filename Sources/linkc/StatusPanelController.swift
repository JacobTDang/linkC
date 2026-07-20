import AppKit
import Observation
import SwiftUI

/// The panel that hosts `PanelView`. Overriding `canBecomeKey` is REQUIRED: without it a
/// borderless/utility panel refuses key status and the embedded SwiftTerm terminal never
/// receives keystrokes.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the menu-bar `NSStatusItem` and the `StatusPanel` that hosts `PanelView`, replacing
/// SwiftUI's `MenuBarExtra(.window)` so we control the panel's position and size.
///
/// Anchoring: on show the panel's top-right corner is pinned just under the status-item icon
/// (falling back to the top-right of the main screen when the icon is unavailable — e.g. in
/// the menu-bar overflow). Sizing: compact when no session is selected, expanded when one is,
/// animating between the two while keeping the same top-right corner fixed so it grows left
/// and down rather than drifting. It is `AppModel` that stays the source of truth — this
/// controller only reflects `selectedId` into the panel's size and mirrors show/hide into
/// `panelVisible`.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: StatusPanel!

    /// The selection value the panel size currently reflects. Guards the selection handler so
    /// that unrelated model changes (e.g. running/waiting counts) don't re-trigger it — only a
    /// genuine `selectedId` transition resizes or auto-opens the panel.
    private var lastSelectedId: String?

    private let defaultCompact = CGSize(width: 360, height: 440)
    private let defaultExpanded = CGSize(width: 840, height: 560)
    private let panelMinSize = CGSize(width: 320, height: 380)
    /// Small gap so the panel sits just below the menu bar / just inside the screen edge.
    private let edgeGap: CGFloat = 6

    private enum SizeKey {
        static let compact = "StatusPanel.compactSize"
        static let expanded = "StatusPanel.expandedSize"
    }

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupStatusItem()
        setupPanel()
        syncFromModel()      // seed the button title + lastSelectedId
        observeModel()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "linkC")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel)
    }

    private func setupPanel() {
        let panel = StatusPanel(
            contentRect: NSRect(origin: .zero, size: defaultCompact),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false        // stays open while the user works elsewhere
        panel.becomesKeyOnlyIfNeeded = false   // full key so the terminal gets keystrokes
        panel.isReleasedWhenClosed = false     // reuse the same panel across show/hide
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = panelMinSize
        // A maximise (zoom) or minimise button makes no sense for a status-bar panel.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
    }

    // MARK: - Toggle / show / hide

    @objc private func togglePanel() {
        if panel.isVisible {
            hide()
        } else {
            present(activating: true)
        }
    }

    /// Show the panel anchored under the status-item icon, sized for the current selection.
    /// Used both by the icon toggle and programmatically (e.g. a notification click that
    /// focuses a session while the panel is hidden).
    func present(activating: Bool) {
        let frame = clampToScreen(anchoredFrame(size: desiredSize()))
        panel.setFrame(frame, display: false)
        model.panelVisible = true
        if activating { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
        focusTerminalIfNeeded()
    }

    func hide() {
        model.panelVisible = false
        panel.orderOut(nil)
    }

    // MARK: - Model observation

    /// Re-registering `@Observable` tracking: SwiftUI drives `PanelView`, but this AppKit
    /// controller needs to react to selection and count changes too. The closure fires once
    /// per change (on will-set), so we hop to the next tick — where the new values are visible
    /// — and re-arm.
    private func observeModel() {
        withObservationTracking {
            _ = model.selectedId
            _ = model.activeCount
            _ = model.needsYouCount
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncFromModel()
                self.observeModel()
            }
        }
    }

    private func syncFromModel() {
        updateStatusButtonTitle()
        let current = model.selectedId
        if current != lastSelectedId {
            lastSelectedId = current
            selectionDidChange(to: current)
        }
    }

    /// A session was selected/deselected. While the panel is open, animate between compact and
    /// expanded (keeping the same top-right corner). While it is hidden, a new selection means
    /// a programmatic focus (notification click) — open the panel to reveal it.
    private func selectionDidChange(to id: String?) {
        if panel.isVisible {
            applySize(desiredSize(), animated: true)
            if id != nil {
                panel.makeKeyAndOrderFront(nil)   // raise on programmatic focus
                focusTerminalIfNeeded()
            }
        } else if id != nil {
            present(activating: true)
        }
    }

    private func updateStatusButtonTitle() {
        guard let button = statusItem.button else { return }
        let active = model.activeCount
        let waiting = model.needsYouCount
        if active == 0 && waiting == 0 {
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = " \(active)·\(waiting)"
            button.imagePosition = .imageLeading
        }
    }

    // MARK: - Sizing

    private func desiredSize() -> CGSize {
        model.selectedId != nil ? expandedSize : compactSize
    }

    private var compactSize: CGSize { atLeastMin(storedSize(SizeKey.compact) ?? defaultCompact) }
    private var expandedSize: CGSize { atLeastMin(storedSize(SizeKey.expanded) ?? defaultExpanded) }

    /// Resize the *visible* panel, keeping its current top-right corner fixed so it grows
    /// left/down instead of drifting.
    private func applySize(_ size: CGSize, animated: Bool) {
        let current = panel.frame
        let target = clampToScreen(NSRect(
            x: current.maxX - size.width,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        ))
        if animated {
            panel.animator().setFrame(target, display: true)
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// A frame whose top-right corner is anchored under the status-item icon, or — when the
    /// icon isn't on screen (menu-bar overflow) — the top-right of the main screen.
    private func anchoredFrame(size: CGSize) -> NSRect {
        if let button = statusItem.button, let window = button.window {
            let iconInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(iconInScreen) }) {
                let visible = screen.visibleFrame
                let topRightX = iconInScreen.maxX
                let topY = visible.maxY - edgeGap
                return NSRect(x: topRightX - size.width, y: topY - size.height, width: size.width, height: size.height)
            }
        }
        // Fallback: icon unavailable / in the overflow — top-right of the main screen.
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let topRightX = visible.maxX - edgeGap
        let topY = visible.maxY - edgeGap
        return NSRect(x: topRightX - size.width, y: topY - size.height, width: size.width, height: size.height)
    }

    /// Keep a frame fully within its screen's visible area. Prefers holding the top edge and
    /// right edge (the anchor), shifting only when it would otherwise spill off screen.
    private func clampToScreen(_ frame: NSRect) -> NSRect {
        let screen = screenContaining(frame) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        return f
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(frame) }
    }

    private func atLeastMin(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, panelMinSize.width), height: max(size.height, panelMinSize.height))
    }

    // MARK: - Terminal focus

    /// Nudge the selected terminal to first responder. `TerminalHostView` already does this
    /// when SwiftUI (re)attaches the view, but re-showing an already-attached terminal after a
    /// hide won't re-run that path, so make it explicit.
    private func focusTerminalIfNeeded() {
        guard model.selectedId != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible,
                  let terminalView = self.model.selectedTerminal?.terminalView else { return }
            self.panel.makeFirstResponder(terminalView)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Red close button: mirror hide() so the coordinator's watch probe stays correct.
        model.panelVisible = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // Only user drags fire this (programmatic animation does not), so it's safe to persist
        // as the preferred size for the current mode.
        let key = model.selectedId != nil ? SizeKey.expanded : SizeKey.compact
        persist(size: panel.frame.size, key: key)
    }

    // MARK: - Size persistence

    private func persist(size: CGSize, key: String) {
        UserDefaults.standard.set(Double(size.width), forKey: key + ".w")
        UserDefaults.standard.set(Double(size.height), forKey: key + ".h")
    }

    private func storedSize(_ key: String) -> CGSize? {
        let w = UserDefaults.standard.double(forKey: key + ".w")
        let h = UserDefaults.standard.double(forKey: key + ".h")
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}
