import Foundation

/// A project's split: the terminals shown together in its Split tab, in grid order, and which one
/// has the keyboard. Members are linkC terminal ids (session ids or shell terminal ids); a session
/// restored after a relaunch keeps its id and so rejoins. Pure value type.
public struct ProjectSplit: Codable, Equatable, Sendable {
    public enum Refusal: Error, Equatable {
        /// The split already holds `SplitLayout.maxPanes` terminals.
        case full
        /// The terminal dropped on is not in this split.
        case targetNotInSplit
    }

    public private(set) var members: [String]
    public private(set) var focused: String?

    public init(members: [String] = [], focused: String? = nil) {
        self.members = members
        self.focused = focused
    }

    /// `id` dropped on `edge` of the member `target`. A member already in the split moves; a new one
    /// joins, unless the split is full. The dropped terminal gets the focus, unless it is dropped on itself,
    /// which returns the split unchanged.
    public func adding(_ id: String, onto target: String, edge: SplitEdge) throws -> ProjectSplit {
        guard let targetIndex = members.firstIndex(of: target) else { throw Refusal.targetNotInSplit }
        guard id != target else { return self }
        let source = members.firstIndex(of: id)
        if source == nil, members.count >= SplitLayout.maxPanes { throw Refusal.full }
        var next = members
        if let source { next.remove(at: source) }
        let index = SplitLayout.insertionIndex(droppingOn: targetIndex, edge: edge, movingFrom: source)
        next.insert(id, at: index)
        return ProjectSplit(members: next, focused: id)
    }

    /// `id` taken out. A focused member hands the focus to the one that takes its place, or to the
    /// one before it when it was last.
    public func removing(_ id: String) -> ProjectSplit {
        guard let index = members.firstIndex(of: id) else { return self }
        var next = members
        next.remove(at: index)
        var focus = focused
        if focused == id { focus = next.isEmpty ? nil : next[min(index, next.count - 1)] }
        return ProjectSplit(members: next, focused: focus)
    }

    public func focusing(_ id: String) -> ProjectSplit {
        guard members.contains(id) else { return self }
        return ProjectSplit(members: members, focused: id)
    }

    /// Only the members in `ids` — the terminals that are live or can still be restored.
    public func pruned(keeping ids: Set<String>) -> ProjectSplit {
        let kept = members.filter { ids.contains($0) }
        let focus = focused.flatMap { kept.contains($0) ? $0 : nil } ?? kept.first
        return ProjectSplit(members: kept, focused: focus)
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

    /// Whether it can ever be a grid: two or more members, live or not. Below that there is nothing
    /// worth keeping, even for a member that comes back on restore.
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
