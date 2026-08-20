import AppKit
import LinkCKit
import Observation
import QuartzCore
import SwiftUI

/// The panel that hosts `PanelView`. Overriding `canBecomeKey` is REQUIRED: without it a
/// borderless/utility panel refuses key status and the embedded SwiftTerm terminal never
/// receives keystrokes.
/// The panel's content host. `mouseDownCanMoveWindow` is the ONE place AppKit asks whether
/// a drag should move the window, so it is answered from a gate the UI can close while the
/// pointer is over selectable text — see `selectableText()`.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    private let gate: WindowDragGate

    init(gate: WindowDragGate, rootView: Content) {
        self.gate = gate
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: Content) {
        fatalError("use init(gate:rootView:)")
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { gate.allowsDrag }
}

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
    /// Whether a drag on the body currently moves the panel. Closed while the pointer is
    /// over text the user may want to select.
    private let dragGate = WindowDragGate()

    /// The selection value the panel width currently reflects. Guards the selection handler so
    /// that unrelated model changes (e.g. running/waiting counts) don't re-trigger it — only a
    /// genuine `selectedId` transition resizes or auto-opens the panel.
    private var lastSelectedId: String?

    /// Width: the user's persisted size, widened for the sidebar split while a session is
    /// selected. Height derives from the persisted size too.
    private let panelMinSize = CGSize(width: 340, height: 220)
    /// Comfortable width for the split (sidebar + terminal). Selection grows the panel to
    /// this when it's too narrow for the split; it never shrinks the panel.
    private let splitTargetWidth: CGFloat = 760
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
        // .popover, not .hudWindow: the softer mid-grey dark glass (what dark-mode menus
        // use) rather than the near-black HUD tint.
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.appearance = NSAppearance(named: .darkAqua)   // dark glass even in Light Mode
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.panelRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor   // glass-edge hairline

        let hosting = PanelHostingView(
            gate: dragGate,
            rootView: PanelView(model: model)
                .environment(\.setWindowDraggable) { [dragGate] in dragGate.setDraggable($0) }
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = effect.bounds
        effect.addSubview(hosting)

        panel.contentView = effect
        panel.delegate = self
        self.panel = panel
    }

    // MARK: - Toggle / show / hide

    @objc func togglePanel() {
        if panel.isVisible {
            hide()
        } else {
            present(activating: true)
        }
    }

    /// Show the panel pinned to the top-right side of the screen, sized for the current
    /// selection. Used both by the icon toggle and programmatically (e.g. a notification click
    /// that focuses a session while the panel is hidden). A fresh appearance settles in with a
    /// short fade + drop from the menu bar; re-presenting an already-visible panel (or Reduce
    /// Motion) skips the motion.
    func present(activating: Bool) {
        let target = anchoredFrame()
        let wasVisible = panel.isVisible
        model.panelVisible = true
        if activating { NSApp.activate(ignoringOtherApps: true) }
        if wasVisible || reduceMotion {
            panel.alphaValue = 1
            panel.setFrame(target, display: false)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.setFrame(target.offsetBy(dx: 0, dy: 10), display: false)   // start just above
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        focusTerminalIfNeeded()
    }

    func hide() {
        model.panelVisible = false
        // The pointer can leave with the panel rather than off the edge of a hovered view,
        // so no exit event arrives; reopening must not find the panel stuck in place.
        dragGate.reset()
        guard panel.isVisible, !reduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let resting = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(resting.offsetBy(dx: 0, dy: 6), display: true)
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread; the closure just isn't annotated.
            MainActor.assumeIsolated {
                guard let self else { return }
                // A present() during the fade wins: it already re-showed the panel at full alpha.
                guard !self.model.panelVisible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.panel.setFrame(resting, display: false)
            }
        })
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
            let previous = lastSelectedId
            lastSelectedId = current
            selectionDidChange(from: previous, to: current)
        }
    }

    /// A session was selected. If the panel is open, raise it + focus its terminal; if hidden (a
    /// programmatic focus, e.g. a notification click), open it to reveal the session. Only the
    /// nil→selected transition widens for the split — switching between sessions must not resize
    /// (in narrow mode the mini-tab strip is the switcher and a resize would swap it away).
    private func selectionDidChange(from previous: String?, to id: String?) {
        guard id != nil else { return }
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)   // raise on programmatic focus
            focusTerminalIfNeeded()
            if previous == nil { ensureSplitWidth() }
        } else {
            present(activating: true)         // panelSize() already accounts for the selection
        }
    }

    /// Grow a too-narrow panel leftward (top-right stays anchored) so the split fits. Only
    /// ever widens — and only below the split's breakpoint, so a user who deliberately keeps
    /// the panel between the breakpoint and the target is left alone.
    private func ensureSplitWidth() {
        guard panel.frame.width < Theme.splitBreakpoint else { return }
        var frame = panel.frame
        frame.origin.x = frame.maxX - splitTargetWidth
        frame.size.width = splitTargetWidth
        frame = clampToScreen(frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
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

    /// The user's persisted (dragged) size, else a small, short default — never below the min.
    /// While a session is selected the width grows to fit the sidebar split, but only when the
    /// persisted width would not fit the split at all — a deliberately kept width between the
    /// breakpoint and the target is honored.
    private func panelSize() -> CGSize {
        let defaultWidth: CGFloat = 480
        let defaultHeight: CGFloat = 300
        let w = UserDefaults.standard.double(forKey: SizeKey.width)
        let h = UserDefaults.standard.double(forKey: SizeKey.height)
        var width = max(w > 0 ? w : defaultWidth, panelMinSize.width)
        // With a terminal open the pane splits into sidebar + terminal — a fresh present
        // starts wide enough for it. A user-dragged size wins when it's already wider.
        if model.selectedId != nil, width < Theme.splitBreakpoint { width = splitTargetWidth }
        return CGSize(
            width: width,
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
