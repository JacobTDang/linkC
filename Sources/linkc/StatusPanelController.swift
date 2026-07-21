import AppKit
import Observation
import QuartzCore
import SwiftUI

/// The panel that hosts `PanelView`. Overriding `canBecomeKey` is REQUIRED: without it a
/// borderless/utility panel refuses key status and the embedded SwiftTerm terminal never
/// receives keystrokes.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Keep the whole panel on-screen — you can't drag it off any edge. AppKit calls this on every
    /// move/resize; we clamp the frame to the screen's visible area (below AppKit's default, which
    /// only keeps the title bar reachable).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        var r = super.constrainFrameRect(frameRect, to: screen)
        guard let visible = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else { return r }
        if r.width <= visible.width {
            if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
            if r.minX < visible.minX { r.origin.x = visible.minX }
        }
        if r.height <= visible.height {
            if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
            if r.minY < visible.minY { r.origin.y = visible.minY }
        }
        return r
    }
}

/// Owns the menu-bar `NSStatusItem` and the frosted `StatusPanel` that hosts `PanelView`,
/// replacing SwiftUI's `MenuBarExtra(.window)` so we control the panel's glass, position, and
/// size.
///
/// Placement: a compact rectangle stuck in the screen's top-right corner. One consistent size
/// regardless of selection: the user's dragged size (persisted) or a small, short default. Movable
/// (drag the body) and resizable (drag edges), always clamped fully on-screen. `AppModel` stays the
/// source of truth — this controller mirrors show/hide into `panelVisible`.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: StatusPanel!

    /// The selection value the panel width currently reflects. Guards the selection handler so
    /// that unrelated model changes (e.g. running/waiting counts) don't re-trigger it — only a
    /// genuine `selectedId` transition resizes or auto-opens the panel.
    private var lastSelectedId: String?

    /// Widths: compact when nothing is selected, expanded when a session is. Height is derived
    /// from the screen (nearly full), so only the width is a stored preference.
    /// One consistent size — a wide rectangle hanging from the icon — regardless of selection. The
    /// user's dragged size is persisted and wins; otherwise a wide default proportional to the screen.
    private let panelMinSize = CGSize(width: 340, height: 220)
    /// Gap below the menu bar / in from the screen edge.
    private let edgeGap: CGFloat = 8

    private enum SizeKey {
        static let width = "StatusPanel.width"
        static let height = "StatusPanel.height"
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
            contentRect: NSRect(origin: .zero, size: CGSize(width: 960, height: 540)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true    // drag the body to MOVE; drag edges/corners to RESIZE
        panel.level = .floating
        panel.hidesOnDeactivate = false        // stays open while the user works elsewhere
        panel.becomesKeyOnlyIfNeeded = false   // full key so the terminal gets keystrokes
        panel.isReleasedWhenClosed = false     // reuse the same panel across show/hide
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = panelMinSize

        // Frosted-glass, rounded, chrome-free: a non-opaque panel whose content is a rounded
        // NSVisualEffectView. Hiding the traffic lights (not just mini/zoom) keeps it clean while
        // `.titled` + `canBecomeKey` still let the terminal take keystrokes.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.appearance = NSAppearance(named: .darkAqua)   // dark glass even in Light Mode
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.panelRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor   // glass-edge hairline

        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = effect.bounds
        effect.addSubview(hosting)

        panel.contentView = effect
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

    /// Show the panel pinned to the top-right side of the screen, sized for the current
    /// selection. Used both by the icon toggle and programmatically (e.g. a notification click
    /// that focuses a session while the panel is hidden).
    func present(activating: Bool) {
        panel.setFrame(anchoredFrame(), display: false)
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
        updateStatusIcon()
        let current = model.selectedId
        if current != lastSelectedId {
            lastSelectedId = current
            selectionDidChange(to: current)
        }
    }

    /// A session was selected. If the panel is open, raise it + focus its terminal; if hidden (a
    /// programmatic focus, e.g. a notification click), open it to reveal the session. No resize —
    /// the panel keeps its one consistent size.
    private func selectionDidChange(to id: String?) {
        guard id != nil else { return }
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)   // raise on programmatic focus
            focusTerminalIfNeeded()
        } else {
            present(activating: true)
        }
    }

    /// The menu-bar icon: tinted the accent (orange) when any session needs your attention,
    /// otherwise the default template colour that follows the menu bar. No count text.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.contentTintColor = model.needsYouCount > 0
            ? NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // accent coral
            : nil
    }

    // MARK: - Sizing

    /// One consistent size: the user's persisted (dragged) size, else a wide default proportional
    /// to the screen — never below the min.
    /// One consistent size: the user's persisted (dragged) size, else a small, short default —
    /// resize when you want more room to work; it persists.
    private func panelSize() -> CGSize {
        let defaultWidth: CGFloat = 480
        let defaultHeight: CGFloat = 300
        let w = UserDefaults.standard.double(forKey: SizeKey.width)
        let h = UserDefaults.standard.double(forKey: SizeKey.height)
        return CGSize(
            width: max(w > 0 ? w : defaultWidth, panelMinSize.width),
            height: max(h > 0 ? h : defaultHeight, panelMinSize.height)
        )
    }

    /// A rectangle stuck in the screen's top-right corner — right + top edges pinned to the corner,
    /// just inside the menu bar. Uses the screen showing the status-item icon (multi-monitor),
    /// never centered.
    private func anchoredFrame() -> NSRect {
        let screen = statusItemScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let size = panelSize()
        let visible = screen.visibleFrame
        let rightX = visible.maxX - edgeGap    // stuck in the top-right corner, not under the icon
        let topY = visible.maxY - edgeGap
        return clampToScreen(NSRect(x: rightX - size.width, y: topY - size.height, width: size.width, height: size.height))
    }

    /// The status-item icon's rect in screen coordinates (nil if it has no window yet — e.g. it's
    /// in the menu-bar overflow).
    private func iconScreenRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func statusItemScreen() -> NSScreen? {
        guard let icon = iconScreenRect() else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(icon) }
    }

    /// Keep a frame fully within its screen's visible area. Prefers holding the top and right
    /// edges (the anchor), shifting only when it would otherwise spill off screen.
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
        // Cmd-W: mirror hide() so the coordinator's watch probe stays correct.
        model.panelVisible = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // User drags fire this (programmatic frame changes don't). Persist the size so it becomes
        // the consistent default on the next open.
        UserDefaults.standard.set(Double(panel.frame.width), forKey: SizeKey.width)
        UserDefaults.standard.set(Double(panel.frame.height), forKey: SizeKey.height)
    }
}
