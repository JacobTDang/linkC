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

extension TornOffItem {
    var isSplit: Bool {
        if case .split = self { true } else { false }
    }

    /// The size a new window for this item opens at: a terminal alone, or a grid.
    public var defaultSize: CGSize {
        switch self {
        case .terminal: CGSize(width: 720, height: 460)
        case .split: CGSize(width: 960, height: 600)
        }
    }

    /// A split window's title: its project's folder name and "Split". A terminal's window is titled with
    /// the terminal's own title, which the app resolves.
    public static func splitTitle(project: String) -> String {
        "\(URL(fileURLWithPath: project).lastPathComponent) \u{2014} Split"
    }
}

extension TornOffFrame {
    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, w: rect.size.width, h: rect.size.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// This frame kept where it is when a screen (each given as its visible frame) holds all of it.
    /// Otherwise it moves onto the screen that holds most of it, or the first when it is on none — the
    /// display it was saved on is gone — by the least that fits it there. One larger than that screen
    /// shrinks to it. With no screens at all there is nothing to fit it to, and it is returned as it is.
    public func clamped(within screens: [CGRect]) -> TornOffFrame {
        let rect = rect
        if screens.contains(where: { $0.contains(rect) }) { return self }
        let overlap = { (screen: CGRect) -> CGFloat in
            let shared = screen.intersection(rect)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        var best = screens.first
        var bestArea: CGFloat = 0
        for screen in screens where overlap(screen) > bestArea {
            best = screen
            bestArea = overlap(screen)
        }
        guard let best else { return self }
        return Self.fitted(origin: rect.origin, size: rect.size, within: best)
    }

    /// The space left between a window opened beside the panel and the panel.
    public static let panelGap = 24.0

    /// A window of `size` centred on `point`, moved the least that keeps it inside `bounds` (a
    /// screen's visible frame). One larger than `bounds` shrinks to it.
    public static func placed(size: CGSize, centredOn point: CGPoint, within bounds: CGRect) -> TornOffFrame {
        fitted(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size, within: bounds)
    }

    /// A window of `size` beside `panel`, its top edge level with the panel's: to the right, or to the
    /// left when the right has no room for it. Where neither side fits, it sits on the right edge of
    /// `bounds`, over the panel.
    public static func placed(size: CGSize, beside panel: CGRect, within bounds: CGRect) -> TornOffFrame {
        let y = panel.maxY - size.height
        let right = panel.maxX + panelGap
        let left = panel.minX - panelGap - size.width
        let x = right + size.width <= bounds.maxX || left < bounds.minX ? right : left
        return fitted(origin: CGPoint(x: x, y: y), size: size, within: bounds)
    }

    private static func fitted(origin: CGPoint, size: CGSize, within bounds: CGRect) -> TornOffFrame {
        let w = min(size.width, bounds.width)
        let h = min(size.height, bounds.height)
        return TornOffFrame(
            x: min(max(origin.x, bounds.minX), bounds.maxX - w),
            y: min(max(origin.y, bounds.minY), bounds.maxY - h),
            w: w, h: h)
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
    /// splits by canonical project path, read only when a split window is open — the sidebar asks for
    /// every row, and building them costs a filesystem call per project. `liveIDs` gives a project's
    /// live terminals.
    public func host(of id: String, splits: @autoclosure () -> [String: ProjectSplit], liveIDs: (String) -> Set<String>) -> TornOffItem? {
        hosts(of: [id], splits: splits(), liveIDs: liveIDs)[id]
    }

    /// `host(of:)` for many terminals at once — a grid asks for every pane — reading the splits once
    /// and each split window's live terminals once. Holds only the ids that live in a window.
    public func hosts(of ids: [String], splits: @autoclosure () -> [String: ProjectSplit],
                      liveIDs: (String) -> Set<String>) -> [String: TornOffItem] {
        var result: [String: TornOffItem] = [:]
        var remaining: [String] = []
        for id in ids {
            if contains(.terminal(id)) { result[id] = .terminal(id) } else { remaining.append(id) }
        }
        guard !remaining.isEmpty, windows.contains(where: { $0.item.isSplit }) else { return result }
        let splits = splits()
        // A terminal belongs to one project, so at most one split window can hold it live; the first
        // one in window order wins should that ever not hold.
        for window in windows {
            guard case .split(let project) = window.item, let split = splits[project] else { continue }
            let members = remaining.filter { split.members.contains($0) }
            guard !members.isEmpty else { continue }
            let live = liveIDs(project)
            guard split.isActive(liveIDs: live) else { continue }
            for id in members where live.contains(id) {
                result[id] = window.item
            }
            remaining.removeAll { result[$0] != nil }
            if remaining.isEmpty { break }
        }
        return result
    }

    /// What the open windows (`open`, by item) must do to match these entries: the entries with no window
    /// yet, in the order they were added, and the windows whose entry is gone.
    public func changes(from open: Set<TornOffItem>) -> (toOpen: [TornOffWindow], toClose: Set<TornOffItem>) {
        let wanted = Set(windows.map(\.item))
        return (windows.filter { !open.contains($0.item) }, open.subtracting(wanted))
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
