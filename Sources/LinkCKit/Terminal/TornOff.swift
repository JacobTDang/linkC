import Foundation

/// What a torn-off window shows: one terminal (a session or shell terminal id), or a project's split
/// grid (by canonical project path).
public enum TornOffItem: Hashable, Codable, Sendable {
    case terminal(String)
    case split(String)
}

/// A window's frame in screen points (AppKit's bottom-left origin).
public struct TornOffFrame: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct TornOffWindow: Equatable, Codable, Sendable {
    public let item: TornOffItem
    public var frame: TornOffFrame

    public init(item: TornOffItem, frame: TornOffFrame) {
        self.item = item
        self.frame = frame
    }
}

/// The torn-off windows, in the order they opened, and the host rule: each terminal has one live view,
/// held by its own window if it has one, else by a window showing an active split that holds it live,
/// else by the panel.
public struct TornOff: Equatable, Sendable {
    public private(set) var windows: [TornOffWindow]

    public init(windows: [TornOffWindow] = []) {
        self.windows = windows
    }

    public var isEmpty: Bool { windows.isEmpty }

    public func contains(_ item: TornOffItem) -> Bool {
        windows.contains { $0.item == item }
    }

    public func frame(of item: TornOffItem) -> TornOffFrame? {
        windows.first { $0.item == item }?.frame
    }

    /// `item` opened at `frame`. One already open stays as it is.
    public func adding(_ item: TornOffItem, frame: TornOffFrame) -> TornOff {
        guard !contains(item) else { return self }
        return TornOff(windows: windows + [TornOffWindow(item: item, frame: frame)])
    }

    public func removing(_ item: TornOffItem) -> TornOff {
        TornOff(windows: windows.filter { $0.item != item })
    }

    /// `item`'s window moved or resized to `frame`. An item that isn't open changes nothing.
    public func framing(_ item: TornOffItem, to frame: TornOffFrame) -> TornOff {
        TornOff(windows: windows.map { $0.item == item ? TornOffWindow(item: item, frame: frame) : $0 })
    }

    /// The window that holds terminal `id`'s live view, or nil for the panel. `splits` are the stored
    /// splits by canonical project path; `liveIDs` gives a project's live terminals.
    public func host(of id: String, splits: [String: ProjectSplit], liveIDs: (String) -> Set<String>) -> TornOffItem? {
        if contains(.terminal(id)) { return .terminal(id) }
        for window in windows {
            guard case .split(let project) = window.item, let split = splits[project],
                  split.members.contains(id) else { continue }
            let live = liveIDs(project)
            if live.contains(id), split.isActive(liveIDs: live) { return window.item }
        }
        return nil
    }

    /// What stays open: terminals still live, splits still active. `closed` is what went, in order.
    public func pruned(liveTerminals: Set<String>, activeSplits: Set<String>) -> (kept: TornOff, closed: [TornOffItem]) {
        var kept: [TornOffWindow] = []
        var closed: [TornOffItem] = []
        for window in windows {
            let stays: Bool
            switch window.item {
            case .terminal(let id): stays = liveTerminals.contains(id)
            case .split(let project): stays = activeSplits.contains(project)
            }
            if stays { kept.append(window) } else { closed.append(window.item) }
        }
        return (TornOff(windows: kept), closed)
    }
}
