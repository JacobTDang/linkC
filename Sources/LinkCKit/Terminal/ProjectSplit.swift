import Foundation

/// A project's split: the terminals shown together in its Split tab, in grid order, which one has the
/// keyboard, and the sizes of its panes once the user has resized them. Members are linkC terminal ids
/// (session ids or shell terminal ids) and are the project's live terminals: one that ends drops out. A
/// session linkC relaunches at start-up keeps its id and so rejoins; one restored later from Earlier is a
/// new session, not in the split. The sizes belong to positions: a member moving keeps them, and a
/// terminal joining or leaving evens the grid out. Pure value type.
public struct ProjectSplit: Codable, Equatable, Sendable {
    public enum Refusal: Error, Equatable {
        /// The split already holds `SplitLayout.maxPanes` terminals.
        case full
        /// The terminal dropped on is not in this split.
        case targetNotInSplit
        /// The project's split is showing (two or more live members) and the terminal dropped on is not
        /// one of its panes. Replacing a split the user is looking at would lose it without asking.
        case splitAlreadyShowing
        /// The dragged terminal or the one it was dropped on is not one of the project's terminals.
        case notSplittable
        /// A terminal was dropped on itself, which splits nothing.
        case onItself
    }

    public private(set) var members: [String]
    public private(set) var focused: String?
    /// How the grid divides its space; nil is even.
    public private(set) var sizes: SplitSizes?

    public init(members: [String] = [], focused: String? = nil, sizes: SplitSizes? = nil) {
        self.members = members
        self.focused = focused
        self.sizes = sizes
    }

    private enum CodingKeys: String, CodingKey { case members, focused, sizes }

    /// A stored split is repaired as it is read: duplicate members would put one terminal in two
    /// cells, more than `SplitLayout.maxPanes` would not fit the grid, and a focus that names no member
    /// would leave no pane with the keyboard. Sizes that don't describe a grid, or that were made for
    /// members the repair changed, are dropped and the grid evens out. Anything repaired is logged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([String].self, forKey: .members)
        let storedFocus = try container.decodeIfPresent(String.self, forKey: .focused)
        var seen: Set<String> = []
        let members = Array(stored.filter { seen.insert($0).inserted }.prefix(SplitLayout.maxPanes))
        var focused = storedFocus
        if let current = focused, !members.contains(current) { focused = members.first }
        if members != stored || focused != storedFocus {
            NSLog("[linkC] a stored split had duplicate or surplus members, or a focus outside them — repaired from %@ (focused %@) to %@ (focused %@)",
                  stored.joined(separator: ","), storedFocus ?? "none", members.joined(separator: ","), focused ?? "none")
        }
        var sizes: SplitSizes?
        do {
            sizes = try container.decodeIfPresent(SplitSizes.self, forKey: .sizes)
        } catch {
            NSLog("[linkC] a stored split's pane sizes were unreadable, so its grid evens out: %@", "\(error)")
        }
        if sizes != nil, members != stored {
            NSLog("[linkC] a stored split's members were repaired, so its pane sizes are dropped and its grid evens out")
            sizes = nil
        }
        self.members = members
        self.focused = focused
        self.sizes = sizes
    }

    /// `id` dropped on `edge` of the member `target`. A member already in the split moves; a new one
    /// joins, unless the split is full. The dropped terminal gets the focus, unless it is dropped on itself,
    /// which returns the split unchanged. A move keeps the sizes; a join evens the grid out.
    public func adding(_ id: String, onto target: String, edge: SplitEdge) throws -> ProjectSplit {
        guard let targetIndex = members.firstIndex(of: target) else { throw Refusal.targetNotInSplit }
        guard id != target else { return self }
        let source = members.firstIndex(of: id)
        if source == nil, members.count >= SplitLayout.maxPanes { throw Refusal.full }
        var next = members
        if let source { next.remove(at: source) }
        let index = SplitLayout.insertionIndex(droppingOn: targetIndex, edge: edge, movingFrom: source)
        next.insert(id, at: index)
        // Sizes belong to positions: a member moving keeps them; one joining reshapes the grid and evens it.
        return ProjectSplit(members: next, focused: id, sizes: source == nil ? nil : sizes)
    }

    /// The split a drop of `id` on `edge` of `target` leaves. Both terminals must be in `splittable`,
    /// the project's own live ones. The `existing` split counts only its `splittable` members, so the
    /// cap and the drop's position match the grid the user sees. `target` in it: `id` joins or moves
    /// there. `target` outside it: a new split from `target` — unless the existing one shows a grid
    /// (two or more live members), which is refused rather than replaced. A terminal dropped on itself
    /// is refused: there is nothing to split.
    public static func dropping(
        _ id: String, onto target: String, edge: SplitEdge, into existing: ProjectSplit?, splittable: Set<String>
    ) throws -> ProjectSplit {
        guard id != target else { throw Refusal.onItself }
        guard splittable.contains(id), splittable.contains(target) else { throw Refusal.notSplittable }
        let live = existing?.pruned(keeping: splittable) ?? ProjectSplit()
        let base: ProjectSplit
        if live.members.contains(target) {
            base = live
        } else if live.isActive(liveIDs: splittable) {
            throw Refusal.splitAlreadyShowing
        } else {
            base = ProjectSplit(members: [target], focused: target)
        }
        return try base.adding(id, onto: target, edge: edge)
    }

    /// `id` taken out. A focused member hands the focus to the one that takes its place, or to the
    /// one before it when it was last. The grid reshapes, so it evens out.
    public func removing(_ id: String) -> ProjectSplit {
        guard let index = members.firstIndex(of: id) else { return self }
        var next = members
        next.remove(at: index)
        var focus = focused
        if focused == id { focus = next.isEmpty ? nil : next[min(index, next.count - 1)] }
        return ProjectSplit(members: next, focused: focus, sizes: nil)
    }

    public func focusing(_ id: String) -> ProjectSplit {
        guard members.contains(id) else { return self }
        return ProjectSplit(members: members, focused: id, sizes: sizes)
    }

    /// Only the members in `ids` — the project's live terminals. The sizes stay only when every member does.
    public func pruned(keeping ids: Set<String>) -> ProjectSplit {
        let kept = members.filter { ids.contains($0) }
        let focus = focused.flatMap { kept.contains($0) ? $0 : nil } ?? kept.first
        return ProjectSplit(members: kept, focused: focus, sizes: kept == members ? sizes : nil)
    }

    /// The split with its panes sized by `sizes`, until a terminal joins or leaves it.
    public func resized(_ sizes: SplitSizes) -> ProjectSplit {
        ProjectSplit(members: members, focused: focused, sizes: sizes)
    }

    /// The sizes a grid of `paneCount` live panes shows: the stored ones when they were made for that
    /// many panes, else even. Sizes that don't fit stay stored for when the missing member is back.
    public func gridSizes(paneCount: Int) -> SplitSizes {
        if let sizes, sizes.fits(paneCount: paneCount) { return sizes }
        return .even(for: paneCount)
    }

    public func liveMembers(in liveIDs: Set<String>) -> [String] {
        members.filter { liveIDs.contains($0) }
    }

    /// The live member with the keyboard: the focused one if it is live, else the first live one.
    public func focusedLive(in liveIDs: Set<String>) -> String? {
        if let focused, liveIDs.contains(focused) { return focused }
        return liveMembers(in: liveIDs).first
    }

    /// Whether there is a grid to show: two or more live members.
    public func isActive(liveIDs: Set<String>) -> Bool {
        liveMembers(in: liveIDs).count >= 2
    }

    /// The project whose split opens when terminal `id` is opened from outside its tab strip (a
    /// sidebar row, a notification): the one whose split holds `id` live and is active. `liveIDs`
    /// gives a project's live terminals. nil when no active split holds it.
    public static func project(opening id: String, in splits: [String: ProjectSplit],
                               liveIDs: (String) -> Set<String>) -> String? {
        // Sorted, so the answer never depends on dictionary order; a terminal is live in one project anyway.
        splits.keys.sorted().first { project in
            guard let split = splits[project], split.members.contains(id) else { return false }
            let live = liveIDs(project)
            return live.contains(id) && split.isActive(liveIDs: live)
        }
    }

    /// Which project's split shows once `selected` is the selected terminal. `current` is the split
    /// showing now; `opened` is what the user just opened (a sidebar row, a notification), nil when
    /// the selection moved by itself. A member of the showing split keeps it. Otherwise the split
    /// holding `selected` opens, but only when the user opened `selected` itself — not a terminal
    /// that turned out to select nothing — and not from its own tab chip (`fullSize`).
    public static func showing(selected: String?, opened: String?, current: String?, fullSize: Bool,
                               splits: [String: ProjectSplit], liveIDs: (String) -> Set<String>) -> String? {
        guard let selected else { return nil }
        if let current, splits[current]?.members.contains(selected) == true { return current }
        guard !fullSize, opened == selected else { return nil }
        return project(opening: selected, in: splits, liveIDs: liveIDs)
    }

    /// Whether it can still be a grid: two or more members, live or not. Below that there is nothing
    /// worth keeping.
    public var isViable: Bool { members.count >= 2 }

    /// What a showing split needs once its members or the selection changed: whether the grid still
    /// has two live panes, and which live member to select when `selected` is not one of them.
    /// A pane that was just taken out is no longer a member, so it never counts as the selection.
    public func repair(selected: String?, liveIDs: Set<String>) -> Repair {
        let live = liveMembers(in: liveIDs)
        if let selected, live.contains(selected) {
            return Repair(keepsGrid: live.count >= 2, select: nil)
        }
        return Repair(keepsGrid: live.count >= 2, select: focusedLive(in: liveIDs))
    }

    public struct Repair: Equatable, Sendable {
        /// Two or more live members are left to show side by side.
        public let keepsGrid: Bool
        /// The live member to select, or nil when the selection can stay (or nothing is live).
        public let select: String?
    }
}
