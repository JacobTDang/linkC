import AppKit
import Observation
import QuartzCore
import SwiftUI

/// The panel that hosts `PanelView`. Overriding `canBecomeKey` is REQUIRED: without it a
/// borderless/utility panel refuses key status and the embedded SwiftTerm terminal never
/// receives keystrokes.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the menu-bar `NSStatusItem` and the frosted `StatusPanel` that hosts `PanelView`,
/// replacing SwiftUI's `MenuBarExtra(.window)` so we control the panel's glass, position, and
/// size.
///
/// Placement: a tall panel pinned to the top-right SIDE of the screen — right edge just inside
/// the screen edge, top just under the menu bar, running nearly the full visible height. Sizing:
/// compact (380) when no session is selected, expanded (760) when one is, animating the width on
/// the `selectedId` flip while keeping the right edge fixed so it grows left. It is `AppModel`
/// that stays the source of truth — this controller only reflects `selectedId` into the width
/// and mirrors show/hide into `panelVisible`.
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
    private let compactWidth: CGFloat = 380
    private let defaultExpandedWidth: CGFloat = 760
    private let panelMinSize = CGSize(width: 320, height: 320)
    /// Gap between the panel and the screen edges (right/top/bottom).
    private let edgeGap: CGFloat = 12

    private enum WidthKey { static let expanded = "StatusPanel.expandedWidth" }

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
            contentRect: NSRect(origin: .zero, size: CGSize(width: compactWidth, height: 600)),
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
        panel.setFrame(anchoredFrame(width: desiredWidth()), display: false)
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

    /// A session was selected/deselected. While the panel is open, animate the width between
    /// compact and expanded (keeping the right edge fixed). While it is hidden, a new selection
    /// means a programmatic focus (notification click) — open the panel to reveal it.
    private func selectionDidChange(to id: String?) {
        if panel.isVisible {
            applyWidth(animated: true)
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

    private func desiredWidth() -> CGFloat {
        model.selectedId != nil ? expandedWidth : compactWidth
    }

    /// The expanded width — the user's persisted preference, or the default, never below the min.
    private var expandedWidth: CGFloat {
        let stored = UserDefaults.standard.double(forKey: WidthKey.expanded)
        return max(stored > 0 ? stored : defaultExpandedWidth, panelMinSize.width)
    }

    /// Resize the *visible* panel to `desiredWidth()`, keeping its current top-right corner fixed
    /// so it grows left instead of drifting. Height is preserved.
    private func applyWidth(animated: Bool) {
        let current = panel.frame
        let target = clampToScreen(NSRect(
            x: current.maxX - desiredWidth(),
            y: current.minY,
            width: desiredWidth(),
            height: current.height
        ))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// A tall frame pinned to the top-right of the target screen's visible area: right edge at
    /// `visibleFrame.maxX - edgeGap`, top at `visibleFrame.maxY - edgeGap`, height nearly the
    /// full visible height. Uses the screen showing the status-item icon, falling back to the
    /// main screen (e.g. when the icon is in the menu-bar overflow) — never centered.
    private func anchoredFrame(width: CGFloat) -> NSRect {
        let screen = statusItemScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let height = visible.height - edgeGap * 2
        let rightX = visible.maxX - edgeGap
        let topY = visible.maxY - edgeGap
        return clampToScreen(NSRect(x: rightX - width, y: topY - height, width: width, height: height))
    }

    private func statusItemScreen() -> NSScreen? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let iconInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSScreen.screens.first { $0.frame.intersects(iconInScreen) }
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
        // Only user drags fire this (programmatic animation does not). Persist the width when
        // expanded — the compact width is fixed and the height is screen-derived.
        guard model.selectedId != nil else { return }
        UserDefaults.standard.set(Double(panel.frame.width), forKey: WidthKey.expanded)
    }
}
