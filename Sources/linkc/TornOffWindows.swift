import AppKit
import LinkCKit
import Observation
import SwiftUI

/// What a torn-off window shows: one terminal on its own, or a project's whole Split grid. The window
/// is a normal macOS window; this is its content, over the panel's glass.
struct TornOffView: View {
    let model: AppModel
    let item: TornOffItem

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
            .tint(Theme.accent)
    }

    /// A grid brings its own drop targets. A single terminal gets none: a drop there would start a split
    /// in the panel and move the panel's selection.
    @ViewBuilder private var content: some View {
        switch item {
        case .terminal(let id): TornOffTerminal(model: model, item: item, id: id)
        case .split(let project): SplitPane(model: model, project: project, host: item)
        }
    }
}

/// A terminal's live view lives in one host. This window is its host while its entry is open; in the
/// moment between the entry going and the window closing, the window hands the view back by showing
/// none, and says where the terminal lives now.
private struct TornOffTerminal: View {
    let model: AppModel
    let item: TornOffItem
    let id: String

    var body: some View {
        let host = model.host(of: id)
        let session = host == item ? model.terminalSession(id) : nil
        ZStack {
            // Reported from AppKit's mouse handling: hand it to the main actor. The weak model breaks the
            // cycle model -> terminals -> session -> view -> this closure.
            TerminalContainer(session: session, takesFocus: true,
                              onClick: { [weak model] in Task { @MainActor in model?.acknowledge(id) } })
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
            if host != item, let host {
                WindowedNote(model: model, item: host)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .onChange(of: session.map(ObjectIdentifier.init), initial: true) { _, _ in
            TerminalStyle.apply(to: session)
        }
    }
}

/// One torn-off window. Carries its item so the delegate knows which window a notification is about.
private final class ItemWindow: NSWindow {
    let item: TornOffItem

    init(item: TornOffItem) {
        self.item = item
        super.init(contentRect: .zero,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
    }

    /// ⌘W closes the window like its close button does. The menus SwiftUI builds for linkC's scene (App,
    /// Edit, View, Window, Help) have no Close item, so nothing else would answer the shortcut.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard TearOffRules.isClose(modifiers: event.modifierFlags, keyCode: event.keyCode,
                                   typed: event.charactersIgnoringModifiers) else { return super.performKeyEquivalent(with: event) }
        performClose(nil)
        return true
    }
}

/// Owns the torn-off windows: one `NSWindow` per `TornOff` entry, kept in step with the model. It opens a
/// window for a new entry at its saved frame, closes the window of a removed one, saves frames as the
/// user moves and resizes, reports the key window to the model, and shows linkC in the Dock and ⌘-Tab
/// while any window is open.
///
/// The model is the source of truth. The user closing a window (the close button, ⌘W) tells the model to
/// bring the item back; the window then goes with the entry. A window closed because its entry went
/// (a terminal ended, Bring back in the panel) is closed with its delegate removed, so it never tells the
/// model again.
@MainActor
final class TornOffWindows: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var windows: [TornOffItem: ItemWindow] = [:]
    /// A window's frame is saved once it has stopped moving: AppKit reports a move at every step of a drag.
    private var pendingSaves: [TornOffItem: Task<Void, Never>] = [:]
    /// Windows in full screen, or going in or out: their frame is not the one to come back to.
    private var inFullScreen: Set<TornOffItem> = []
    /// Set once linkC is quitting. A window that closes from here on is not the user closing it, so it
    /// must stay in the model and reopen on the next launch.
    private var terminating = false

    private static let minSize = NSSize(width: 360, height: 240)
    private static let saveDelay = Duration.milliseconds(250)

    /// Opens the windows the model has: at launch these are the saved ones that survived start-up's
    /// prune, so only live terminals and active splits come back.
    init(model: AppModel) {
        self.model = model
        super.init()
        model.onRaiseWindow = { [weak self] item in self?.raise(item) }
        reconcile(openedByUser: false)
        observeModel()
    }

    // MARK: - Following the model

    /// The same `withObservationTracking` re-arm loop `StatusPanelController` uses. The change callback only
    /// schedules the work on the main actor: by then the new values are visible. What is read here is
    /// what the windows show: the entries, and the titles. A title comes from inputs Observation can't
    /// see (inbox files, terminal screens); the sweep publishes those through `sidebarSignal`.
    private func observeModel() {
        withObservationTracking {
            _ = model.tornOff
            _ = model.sidebarSignal.signal
            if !windows.isEmpty {
                let titles = model.sessionTitles
                for item in windows.keys { _ = model.windowTitle(for: item, titles: titles) }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Only `tearOff` adds entries, and it is the user's doing: every window that shows up
                // through this hop was opened by them. Windows that come back at launch go through `init`.
                self.reconcile(openedByUser: true)
                self.observeModel()
            }
        }
    }

    /// Opens what is missing, closes what is gone, refreshes the titles and sets the activation policy.
    /// `openedByUser`: a window that opens now is one the user just made, so it takes the keyboard and
    /// linkC comes forward. Windows restored at launch are ordered to the front of their level, over other
    /// apps' windows, but linkC isn't activated and the keyboard stays where it was.
    private func reconcile(openedByUser: Bool) {
        let changes = model.tornOff.changes(from: Set(windows.keys))
        for item in changes.toClose { close(item) }
        let titles = model.sessionTitles
        let created = changes.toOpen.map { makeWindow(for: $0, titles: titles) }
        for (item, window) in windows {
            let title = model.windowTitle(for: item, titles: titles)
            if window.title != title { window.title = title }
        }
        // Before any window shows: a window of an accessory app can't take the keyboard.
        updateActivationPolicy()
        if openedByUser, !created.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            for window in created { window.makeKeyAndOrderFront(nil) }
        } else {
            for window in created { window.orderFront(nil) }
        }
    }

    /// linkC is in the Dock and ⌘-Tab, with a menu bar, while a window is open; menu-bar only when none is.
    /// Set only when it changes.
    private func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = windows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        guard NSApp.setActivationPolicy(wanted) else {
            NSLog("[linkC] windows: could not switch the activation policy to %@", wanted == .regular ? "regular" : "accessory")
            return
        }
        // The last window is gone and linkC would stay the active app with nothing on screen and the
        // keyboard still its own: hide it so the previous app gets the keyboard back. Not while the panel
        // shows, not when linkC isn't active (hiding would take focus from the app in use), and not over a
        // modal dialog, which would then run unseen.
        if wanted == .accessory, !model.panelVisible, NSApp.isActive, NSApp.modalWindow == nil { NSApp.hide(nil) }
    }

    // MARK: - Opening and closing

    private func makeWindow(for entry: TornOffWindow, titles: [String: String]) -> ItemWindow {
        let window = ItemWindow(item: entry.item)
        window.title = model.windowTitle(for: entry.item, titles: titles)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        // "Prefer tabs: Always" would merge every torn-off window into one tabbed window.
        window.tabbingMode = .disallowed
        window.minSize = Self.minSize
        // The panel's dark glass, even in Light Mode: the window must let it show through, and the
        // title and traffic lights must read on it.
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        // The saved frame, moved back onto a screen that is still there if its display was unplugged.
        let screens = NSScreen.screens.map(\.visibleFrame)
        window.setFrame(entry.frame.clamped(within: screens).rect, display: false)

        let glass = NSVisualEffectView.linkCGlass()
        let hosting = NSHostingView(rootView: TornOffView(model: model, item: entry.item))
        // The window decides its size; the content only fills it.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hosting)
        window.contentView = glass
        // The glass runs under the transparent title bar; the content starts below it.
        let top: NSLayoutYAxisAnchor
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            top = guide.topAnchor
        } else {
            NSLog("[linkC] windows: no content layout guide for %@; the content may run under the title bar", String(describing: entry.item))
            top = glass.topAnchor
        }
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: top),
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        window.delegate = self
        windows[entry.item] = window
        return window
    }

    /// Closes the window of an entry that is gone. Its delegate goes first: `windowWillClose` is for the
    /// user's close, which brings the item back, and this item is already out of the model.
    private func close(_ item: TornOffItem) {
        guard let window = windows.removeValue(forKey: item) else { return }
        forget(item)
        window.delegate = nil
        // Resign-key would have said so, and the delegate no longer hears it.
        if model.keyWindowItem == item { model.setKeyWindowItem(nil) }
        window.close()
    }

    private func forget(_ item: TornOffItem) {
        pendingSaves.removeValue(forKey: item)?.cancel()
        inFullScreen.remove(item)
    }

    /// Brings `item`'s window forward and gives it the keyboard. activate first: the window stays key
    /// once linkC is the active app.
    private func raise(_ item: TornOffItem) {
        // The model can ask for a window in the same turn it added the entry, before the observation hop.
        if windows[item] == nil { reconcile(openedByUser: true) }
        guard let window = windows[item] else {
            NSLog("[linkC] windows: asked to raise a window that isn't open: %@", String(describing: item))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Quitting

    /// linkC is about to quit. From here on a window closing is AppKit tearing the app down, not the user:
    /// `windowWillClose` leaves the entries in the model, so the windows come back on the next launch.
    func prepareForQuit() {
        terminating = true
        // A move still waiting out its save delay would be lost with the window: save every frame now.
        for window in windows.values { saveFrame(of: window) }
    }

    // MARK: - NSWindowDelegate

    /// The user closed the window (its close button or ⌘W): the item goes back to the panel and the
    /// window goes with its entry. Windows closed by `close(_:)` have no delegate and never get here.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? ItemWindow else { return }
        let item = window.item
        if windows[item] === window { windows[item] = nil }
        forget(item)
        // While the entry is still there, so what the window showed is marked seen.
        if model.keyWindowItem == item { model.setKeyWindowItem(nil) }
        if !terminating { model.bringBack(item) }
    }

    /// The window a notification is about, unless it has been closed: a closed window no longer speaks
    /// for its item, and a new window for the same item may already be open.
    private func openWindow(_ notification: Notification) -> ItemWindow? {
        guard let window = notification.object as? ItemWindow, windows[window.item] === window else { return nil }
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = openWindow(notification) else { return }
        model.setKeyWindowItem(window.item)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = openWindow(notification), model.keyWindowItem == window.item else { return }
        model.setKeyWindowItem(nil)
    }

    /// Dragging an edge or corner moves the origin too: a resize drag is saved once, at its end.
    func windowDidMove(_ notification: Notification) {
        guard let window = openWindow(notification), !window.inLiveResize else { return }
        saveFrameWhenSettled(window)
    }

    /// A resize that isn't a drag (zoom, a double-click on the title bar) comes here; a drag is saved once,
    /// at its end.
    func windowDidResize(_ notification: Notification) {
        guard let window = openWindow(notification), !window.inLiveResize else { return }
        saveFrameWhenSettled(window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = openWindow(notification) else { return }
        saveFrame(of: window)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = openWindow(notification) else { return }
        pendingSaves.removeValue(forKey: window.item)?.cancel()
        inFullScreen.insert(window.item)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = openWindow(notification) else { return }
        inFullScreen.remove(window.item)
        saveFrame(of: window)
    }

    /// A transition that failed leaves no `windowDidExitFullScreen` to follow `windowWillEnterFullScreen`:
    /// without this the window would never save its frame again.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard let window = window as? ItemWindow, windows[window.item] === window else { return }
        inFullScreen.remove(window.item)
    }

    /// A window that failed to leave full screen is still in it: its frame stays unsaved until it does.
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard let window = window as? ItemWindow, windows[window.item] === window else { return }
        if window.styleMask.contains(.fullScreen) {
            inFullScreen.insert(window.item)
        } else {
            inFullScreen.remove(window.item)
        }
    }

    private func saveFrameWhenSettled(_ window: ItemWindow) {
        let item = window.item
        guard !inFullScreen.contains(item) else { return }
        pendingSaves.removeValue(forKey: item)?.cancel()
        pendingSaves[item] = Task { [weak self, weak window] in
            do {
                try await Task.sleep(for: Self.saveDelay)
            } catch {
                return   // cancelled: a later move or the window's close replaced this save
            }
            guard !Task.isCancelled, let self, let window else { return }
            self.pendingSaves[item] = nil
            self.saveFrame(of: window)
        }
    }

    private func saveFrame(of window: ItemWindow) {
        guard !inFullScreen.contains(window.item) else { return }
        pendingSaves.removeValue(forKey: window.item)?.cancel()
        model.setFrame(window.item, TornOffFrame(window.frame))
    }
}
