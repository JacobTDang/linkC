import Foundation

/// Merges two edited copies of a `BoardMap` against the version both started from, element by
/// element: whoever changed an element wins, and `mine` wins a tie. Pure and non-isolated — no
/// I/O, and it never lays anything out; `BoardModel.laidOut` runs after a merge, not inside it.
public enum BoardMerge {
    public static func merge(base: BoardMap, mine: BoardMap, theirs: BoardMap) -> BoardMap {
        var merged = BoardMap(system: pick(base.system, mine.system, theirs.system))
        merged.components = mergedKeyedList(
            base: base.components, mine: mine.components, theirs: theirs.components,
            key: { $0.name.lowercased() }, whenBothChanged: mergedComponent)
        merged.frames = mergedKeyedList(
            base: base.frames, mine: mine.frames, theirs: theirs.frames,
            key: { $0.label.lowercased() }, whenBothChanged: mergedFrame)
        merged.notes = mergedNotes(base: base.notes, mine: mine.notes, theirs: theirs.notes)
        merged.texts = mergedTexts(base: base.texts, mine: mine.texts, theirs: theirs.texts)
        // The Board never edits either extras blob: whichever unknown keys theirs carried win.
        merged.extras = theirs.extras
        merged.layoutExtras = theirs.layoutExtras
        return merged
    }

    // MARK: - The one merge rule

    /// `pick(b, m, t) = m != b ? m : t`: whoever changed a value wins; mine wins a tie.
    private static func pick<T: Equatable>(_ base: T, _ mine: T, _ theirs: T) -> T {
        mine != base ? mine : theirs
    }

    /// The same rule at element granularity: `nil` means absent.
    /// - Mine unchanged (equals base) → take theirs, deleted or not.
    /// - Theirs unchanged (equals base) → take mine, deleted or not.
    /// - Both changed, and one of them deleted it → the other side wins (it is a real edit).
    /// - Both changed and both are present: field-merge them, unless base never had this
    ///   element at all — then both sides independently added it, and mine wins outright.
    private static func mergeElement<T: Equatable>(
        base: T?, mine: T?, theirs: T?, whenBothChanged: (T, T, T) -> T
    ) -> T? {
        if mine == base { return theirs }
        if theirs == base { return mine }
        guard let mine else { return nil }
        guard let theirs else { return mine }
        guard let base else { return mine }
        return whenBothChanged(base, mine, theirs)
    }

    // MARK: - Components and frames: keyed lists, merged element by element

    /// Merges two lists keyed by a lowercased identity, in `theirs`' order, then mine-only
    /// additions in mine's order. Shared by components (keyed by name) and frames (keyed by
    /// label) — the ordering and element-merge rule is identical for both.
    private static func mergedKeyedList<T: Equatable>(
        base: [T], mine: [T], theirs: [T], key: (T) -> String, whenBothChanged: (T, T, T) -> T
    ) -> [T] {
        let baseByKey = Dictionary(base.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let mineByKey = Dictionary(mine.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let theirsByKey = Dictionary(theirs.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })

        var result: [T] = []
        var processed: Set<String> = []
        for item in theirs + mine {
            let itemKey = key(item)
            guard processed.insert(itemKey).inserted else { continue }
            if let merged = mergeElement(base: baseByKey[itemKey], mine: mineByKey[itemKey], theirs: theirsByKey[itemKey], whenBothChanged: whenBothChanged) {
                result.append(merged)
            }
        }
        return result
    }

    private static func mergedComponent(_ base: BoardComponent, _ mine: BoardComponent, _ theirs: BoardComponent) -> BoardComponent {
        var merged = base
        merged.name = pick(base.name, mine.name, theirs.name)
        merged.kind = pick(base.kind, mine.kind, theirs.kind)
        merged.does = pick(base.does, mine.does, theirs.does)
        merged.reachedBy = pick(base.reachedBy, mine.reachedBy, theirs.reachedBy)
        merged.runs = pick(base.runs, mine.runs, theirs.runs)
        merged.planned = pick(base.planned, mine.planned, theirs.planned)
        merged.uses = mergedUses(base.uses, mine.uses, theirs.uses)
        merged.legacyUsedBy = pick(base.legacyUsedBy, mine.legacyUsedBy, theirs.legacyUsedBy)
        merged.place = pick(base.place, mine.place, theirs.place)
        merged.at = pick(base.at, mine.at, theirs.at)
        merged.extras = pick(base.extras, mine.extras, theirs.extras)
        return merged
    }

    /// `uses`, per target key with `pick`: a key only one side ever touched keeps that side's
    /// label; a key both sides changed goes to whoever actually moved it off base.
    private static func mergedUses(_ base: [String: String], _ mine: [String: String], _ theirs: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in Set(base.keys).union(mine.keys).union(theirs.keys) {
            if let value = pick(base[key], mine[key], theirs[key]) {
                result[key] = value
            }
        }
        return result
    }

    private static func mergedFrame(_ base: BoardFrame, _ mine: BoardFrame, _ theirs: BoardFrame) -> BoardFrame {
        var merged = base
        merged.label = pick(base.label, mine.label, theirs.label)
        merged.rect = pick(base.rect, mine.rect, theirs.rect)
        return merged
    }

    // MARK: - Notes: identity is the text, a multiset — every decode mints fresh ids

    /// Theirs' notes, minus texts mine removed (in base, not in mine), plus notes mine added
    /// (not in base), keeping mine's positions. A note surviving in all three takes `at` by
    /// `pick` and keeps mine's id.
    private static func mergedNotes(base: [BoardNote], mine: [BoardNote], theirs: [BoardNote]) -> [BoardNote] {
        var result: [BoardNote] = []
        for text in orderedTexts(theirs: theirs.map(\.text), mine: mine.map(\.text)) {
            let baseGroup = base.filter { $0.text == text }
            let mineGroup = mine.filter { $0.text == text }
            let theirsGroup = theirs.filter { $0.text == text }
            result += mergedNoteGroup(baseGroup, mineGroup, theirsGroup)
        }
        return result
    }

    /// One text's instances, reconciled as a multiset: however many survive in all three are
    /// paired up (by position within the group) and take `at` by `pick`, keeping mine's id;
    /// whatever theirs has beyond what mine deleted stays theirs; whatever mine added beyond
    /// base is appended as mine's own notes.
    private static func mergedNoteGroup(_ base: [BoardNote], _ mine: [BoardNote], _ theirs: [BoardNote]) -> [BoardNote] {
        let matched = min(base.count, mine.count, theirs.count)
        var group: [BoardNote] = (0..<matched).map { index in
            BoardNote(id: mine[index].id, text: mine[index].text, at: pick(base[index].at, mine[index].at, theirs[index].at))
        }
        let removedByMine = max(0, base.count - mine.count)
        let keptFromTheirs = max(0, theirs.count - removedByMine)
        group += theirs.dropFirst(matched).prefix(max(0, keptFromTheirs - matched))
        let addedByMine = max(0, mine.count - base.count)
        group += mine.suffix(addedByMine)
        return group
    }

    /// Distinct texts, in theirs' order, then mine-only additions in mine's order.
    private static func orderedTexts(theirs: [String], mine: [String]) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for text in theirs + mine where seen.insert(text).inserted { order.append(text) }
        return order
    }

    // MARK: - Texts: identity is (text, style), the same multiset approach

    private struct TextKey: Hashable {
        let text: String
        let style: BoardTextStyle
    }

    private static func mergedTexts(base: [BoardText], mine: [BoardText], theirs: [BoardText]) -> [BoardText] {
        func key(_ text: BoardText) -> TextKey { TextKey(text: text.text, style: text.style) }
        var seen: Set<TextKey> = []
        var order: [TextKey] = []
        for text in theirs.map(key) + mine.map(key) where seen.insert(text).inserted { order.append(text) }

        var result: [BoardText] = []
        for textKey in order {
            let baseGroup = base.filter { key($0) == textKey }
            let mineGroup = mine.filter { key($0) == textKey }
            let theirsGroup = theirs.filter { key($0) == textKey }
            result += mergedTextGroup(baseGroup, mineGroup, theirsGroup)
        }
        return result
    }

    /// Same reconciliation as a note group, but a surviving-in-all-three text also takes
    /// `width` and `extras` by `pick`, alongside `at`.
    private static func mergedTextGroup(_ base: [BoardText], _ mine: [BoardText], _ theirs: [BoardText]) -> [BoardText] {
        let matched = min(base.count, mine.count, theirs.count)
        var group: [BoardText] = (0..<matched).map { index in
            var text = BoardText(
                id: mine[index].id, text: mine[index].text, style: mine[index].style,
                at: pick(base[index].at, mine[index].at, theirs[index].at),
                width: pick(base[index].width, mine[index].width, theirs[index].width))
            text.extras = pick(base[index].extras, mine[index].extras, theirs[index].extras)
            return text
        }
        let removedByMine = max(0, base.count - mine.count)
        let keptFromTheirs = max(0, theirs.count - removedByMine)
        group += theirs.dropFirst(matched).prefix(max(0, keptFromTheirs - matched))
        let addedByMine = max(0, mine.count - base.count)
        group += mine.suffix(addedByMine)
        return group
    }
}
