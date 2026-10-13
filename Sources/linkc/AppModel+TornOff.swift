import AppKit
import LinkCKit

/// Terminals and splits that live in their own windows. The windows belong to the window controller:
/// it follows `tornOff`, opens and closes them, and reports the key one through `keyWindowItem`.
/// Writers are `tearOff`, `bringBack`, `setFrame` and `pruneTornOff()` — never a view body.
extension AppModel {
    var tornOff: TornOff { sidebarState.tornOff }

    /// The window that holds terminal `id`'s live view, or nil for the panel. Asked often, so it does
    /// no work at all while nothing is torn off.
    func host(of id: String) -> TornOffItem? {
        guard !tornOff.isEmpty else { return nil }
        return tornOff.host(of: id, splits: storedSplits(), liveIDs: { splittableIDs(in: $0) })
    }

    /// The terminal the key torn-off window is showing: its own, or its split's focused live pane. nil
    /// once that window is gone, whether or not the controller has reported it yet.
    var keyWindowSessionId: String? {
        guard let item = keyWindowItem, tornOff.contains(item) else { return nil }
        switch item {
        case .terminal(let id): return id
        case .split(let project): return sidebarState.split(for: project)?.focusedLive(in: splittableIDs(in: project))
        }
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
        sidebarState.setTornOff(tornOff.adding(item, frame: frame))
    }

    /// Puts `item` back in the panel: its window closes, the session keeps running.
    func bringBack(_ item: TornOffItem) {
        sidebarState.setTornOff(tornOff.removing(item))
    }

    func setFrame(_ item: TornOffItem, _ frame: TornOffFrame) {
        sidebarState.setTornOff(tornOff.framing(item, to: frame))
    }

    /// Brings `item`'s window forward. For a split, `id` first becomes the pane that has the focus.
    func raise(_ item: TornOffItem, focusing id: String?) {
        if case .split(let project) = item, let id { focusInSplit(id, in: project) }
        onRaiseWindow?(item)
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
