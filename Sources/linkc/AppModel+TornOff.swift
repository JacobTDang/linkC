import AppKit
import LinkCKit

/// Terminals and splits that live in their own windows. The windows belong to the window controller:
/// it follows `tornOff`, opens and closes them, and reports the key one through `setKeyWindowItem(_:)`.
/// Writers are `tearOff`, `bringBack`, `setFrame` and `pruneTornOff()` — never a view body.
extension AppModel {
    var tornOff: TornOff { sidebarState.tornOff }

    /// The windows that hold the live views of `ids`, containing only the ids that live in a window.
    /// Fast return when nothing is torn off, and builds the stored splits and live-ID sets once.
    func hosts(of ids: [String]) -> [String: TornOffItem] {
        guard !tornOff.isEmpty, !ids.isEmpty else { return [:] }
        var remaining = Set(ids)
        var result: [String: TornOffItem] = [:]
        for id in remaining {
            if tornOff.contains(.terminal(id)) {
                result[id] = .terminal(id)
            }
        }
        remaining.subtract(result.keys)
        guard !remaining.isEmpty, tornOff.windows.contains(where: {
            if case .split = $0.item { true } else { false }
        }) else { return result }
        let splits = storedSplits()
        for window in tornOff.windows {
            guard case .split(let project) = window.item, let split = splits[project] else { continue }
            let candidates = remaining.intersection(split.members)
            guard !candidates.isEmpty else { continue }
            let live = splittableIDs(in: project)
            guard split.isActive(liveIDs: live) else { continue }
            for id in candidates where live.contains(id) {
                result[id] = window.item
                remaining.remove(id)
            }
            if remaining.isEmpty { break }
        }
        return result
    }

    /// The window that holds terminal `id`'s live view, or nil for the panel. Asked for every sidebar
    /// row, so it does no work while nothing is torn off, and builds the stored splits only when a split
    /// window is open.
    func host(of id: String) -> TornOffItem? {
        hosts(of: [id])[id]
    }

    /// The terminal the key torn-off window is showing: its own, or its split's focused live pane — when
    /// that pane lives in the split's window, not in a window of its own, where the split shows only a
    /// note. nil once that window is gone, whether or not the controller has reported it yet.
    var keyWindowSessionId: String? {
        guard let item = keyWindowItem, tornOff.contains(item) else { return nil }
        switch item {
        case .terminal(let id):
            return id
        case .split(let project):
            guard let id = sidebarState.split(for: project)?.focusedLive(in: splittableIDs(in: project)),
                  host(of: id) == item else { return nil }
            return id
        }
    }

    /// The coordinator's sweep runs its app-side sampling (`sampleShells()`, `sampleSidebar()`) while
    /// the panel is open or any torn-off window is. `panelVisible` itself still means the panel only:
    /// `onScreenSessionId`, `isWatching` and the usage timer depend on that. Without the windows
    /// counted, a hidden panel stops the sweep for good: an ended terminal's window never closes, the key
    /// window's session is never marked seen and shell titles go stale. Called wherever either side
    /// changes: `panelVisible`, `tearOff`, `bringBack`, `pruneTornOff()` and `start()`.
    func syncSweepVisibility() {
        coordinator?.setPanelVisible(panelVisible || !tornOff.isEmpty)
    }

    /// Every live terminal: the sessions and the shell terminals.
    var liveTerminalIDs: Set<String> {
        Set(sessions.map(\.id)).union(shellRows.map(\.id))
    }

    /// Whether `project`'s split has a grid to show: two or more live members.
    func splitIsActive(_ project: String) -> Bool {
        sidebarState.split(for: project)?.isActive(liveIDs: splittableIDs(in: project)) ?? false
    }

    /// Opens `item` in its own window, centred on `point` (screen coordinates), or beside the panel when
    /// there is none. An item already in a window brings it forward instead. A terminal that has
    /// ended, or a split with fewer than two running terminals, is refused and the error bar says why.
    func tearOff(_ item: TornOffItem, at point: CGPoint?) {
        let item = standardized(item)
        switch item {
        case .terminal(let id):
            guard liveTerminalIDs.contains(id) else {
                surface(error: "That terminal has ended, so it can't open in a window.")
                return
            }
        case .split(let project):
            guard splitIsActive(project) else {
                surface(error: "This split needs two running terminals to open in a window.")
                return
            }
        }
        if tornOff.contains(item) {
            raise(item, focusing: nil)
            return
        }
        guard let frame = newWindowFrame(for: item, at: point) else { return }
        markOnScreenSeen()   // what the panel shows now is about to leave it
        sidebarState.setTornOff(tornOff.adding(item, frame: frame))
        syncSweepVisibility()
    }

    /// Puts `item` back in the panel: its window closes, the session keeps running. Also the way a
    /// window closes on the user's behalf, so any other window whose terminal has ended closes with it.
    func bringBack(_ item: TornOffItem) {
        let item = standardized(item)
        guard tornOff.contains(item) else { return }
        markOnScreenSeen()   // the window may be the key one: what it showed was on screen until now
        sidebarState.setTornOff(tornOff.removing(item))
        pruneTornOff()
        syncSweepVisibility()
    }

    func setFrame(_ item: TornOffItem, _ frame: TornOffFrame) {
        sidebarState.setTornOff(tornOff.framing(item, to: frame))
    }

    /// Brings `item`'s window forward. For a split, `id` first becomes the pane that has the focus. An
    /// item that isn't open does nothing: a "Show window" button can outlive its window.
    func raise(_ item: TornOffItem, focusing id: String?) {
        let item = standardized(item)
        guard tornOff.contains(item) else { return }
        if case .split(let project) = item, let id { focusInSplit(id, in: project) }
        onRaiseWindow?(item)
    }

    /// A window's title: a terminal's is the one its tab strip shows (its live title, else the stored
    /// one), a split's is its project's folder and "Split". `titles` is `sessionTitles`, resolved once
    /// for all the windows.
    func windowTitle(for item: TornOffItem, titles: [String: String]) -> String {
        switch item {
        case .terminal(let id): splitPaneTitle(id, titles: titles)
        case .split(let project): TornOffItem.splitTitle(project: project)
        }
    }

    /// The user clicked in a window's terminal: it is opened as clicking its tab opens it, minus the
    /// selection the panel keeps.
    func acknowledge(_ id: String) {
        coordinator?.acknowledgeSession(id)
    }

    /// Windows are keyed by canonical project path, the form `host(of:)` and `pruneTornOff()` compare.
    private func standardized(_ item: TornOffItem) -> TornOffItem {
        guard case .split(let project) = item else { return item }
        return .split(ProjectTabs.standardized(project))
    }

    /// Where a new window for `item` opens, on the screen holding `point` — or holding the panel when
    /// there is no point. nil, with the error bar saying why, when there is nowhere to put it.
    private func newWindowFrame(for item: TornOffItem, at point: CGPoint?) -> TornOffFrame? {
        let size = item.defaultSize
        if let point, let screen = screen(holding: point) {
            return .placed(size: size, centredOn: point, within: screen.visibleFrame)
        }
        if point == nil, let panel = panelFrame(), let screen = screen(holding: CGPoint(x: panel.midX, y: panel.midY)) {
            return .placed(size: size, beside: panel, within: screen.visibleFrame)
        }
        surface(error: "Couldn't open the window: there is nowhere to put it.")
        return nil
    }

    private func screen(holding point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
