import Foundation

/// Merges two edited copies of a `BoardMap` against the version both started from, element by
/// element: whoever changed an element wins, and `mine` wins a tie — a deletion counts as a
/// change, so mine deleting something beats theirs editing it, and theirs deleting something
/// loses to mine editing it. The merge result is written to disk, so a wrong merge silently loses
/// someone's work. Pure and non-isolated — no I/O, and it never lays anything out;
/// `BoardModel.laidOut` runs after a merge, not inside it.
///
/// **Known limit — renames.** Nothing here detects a rename. Renaming a component, a frame, a
/// note or a text is, structurally, deleting the old one and adding a new one under a different
/// identity (name, label, or text). If the other side edited the *old* identity at the very same
/// moment, that edit has nowhere left to land in the merged map and is lost. This is an accepted
/// limit, not a bug to chase.
public enum BoardMerge {
    public static func merge(base: BoardMap, mine: BoardMap, theirs: BoardMap) -> BoardMap {
        var merged = BoardMap(system: pick(base.system, mine.system, theirs.system))
        merged.components = mergedKeyedList(
            base: base.components, mine: mine.components, theirs: theirs.components,
            key: { $0.name.lowercased() },
            whenBothChanged: { componentBase, componentMine, componentTheirs in
                mergedComponent(
                    componentBase, componentMine, componentTheirs,
                    componentsBase: base.components, componentsMine: mine.components, componentsTheirs: theirs.components)
            })
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

    private static func mergedComponent(
        _ base: BoardComponent, _ mine: BoardComponent, _ theirs: BoardComponent,
        componentsBase: [BoardComponent], componentsMine: [BoardComponent], componentsTheirs: [BoardComponent]
    ) -> BoardComponent {
        var merged = base
        merged.name = pick(base.name, mine.name, theirs.name)
        merged.kind = pick(base.kind, mine.kind, theirs.kind)
        merged.does = pick(base.does, mine.does, theirs.does)
        merged.reachedBy = pick(base.reachedBy, mine.reachedBy, theirs.reachedBy)
        merged.runs = pick(base.runs, mine.runs, theirs.runs)
        merged.planned = pick(base.planned, mine.planned, theirs.planned)
        merged.uses = mergedUses(
            base.uses, mine.uses, theirs.uses,
            componentsBase: componentsBase, componentsMine: componentsMine, componentsTheirs: componentsTheirs)
        merged.legacyUsedBy = pick(base.legacyUsedBy, mine.legacyUsedBy, theirs.legacyUsedBy)
        merged.place = pick(base.place, mine.place, theirs.place)
        merged.at = pick(base.at, mine.at, theirs.at)
        merged.extras = pick(base.extras, mine.extras, theirs.extras)
        return merged
    }

    /// `uses`, per lowercased target key — `BoardEdit` folds arrow keys the same way when the
    /// Board itself edits `uses`, so a hand-edit that only recases a key, with no real change,
    /// must never mint a second arrow here. A key only one side ever touched keeps that side's
    /// label; a key both sides changed goes to whoever actually moved it off base. The merged
    /// key's spelling is the target component's real name in the merged map when one survives
    /// there — that is the name the arrow should point at — else mine's spelling of the key, else
    /// theirs'.
    private static func mergedUses(
        _ base: [String: String], _ mine: [String: String], _ theirs: [String: String],
        componentsBase: [BoardComponent], componentsMine: [BoardComponent], componentsTheirs: [BoardComponent]
    ) -> [String: String] {
        let baseByKey = lowercasedKeyed(base)
        let mineByKey = lowercasedKeyed(mine)
        let theirsByKey = lowercasedKeyed(theirs)
        var result: [String: String] = [:]
        for lowerKey in Set(baseByKey.keys).union(mineByKey.keys).union(theirsByKey.keys) {
            guard let value = pick(baseByKey[lowerKey]?.value, mineByKey[lowerKey]?.value, theirsByKey[lowerKey]?.value) else { continue }
            let realName = mergedComponentName(
                forLowercasedKey: lowerKey, base: componentsBase, mine: componentsMine, theirs: componentsTheirs)
            let key = realName ?? mineByKey[lowerKey]?.key ?? theirsByKey[lowerKey]?.key ?? lowerKey
            result[key] = value
        }
        return result
    }

    /// `uses`' keys, grouped by their lowercased form, each still holding its original spelling.
    private static func lowercasedKeyed(_ uses: [String: String]) -> [String: (key: String, value: String)] {
        Dictionary(uses.map { ($0.key.lowercased(), (key: $0.key, value: $0.value)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The name a component keyed by `key` (lowercased) would have in the merged map — nil when no
    /// side keeps a component there. Resolves only `name`, not the whole component: merging its
    /// own `uses` too would recurse if two components used each other.
    private static func mergedComponentName(
        forLowercasedKey key: String, base: [BoardComponent], mine: [BoardComponent], theirs: [BoardComponent]
    ) -> String? {
        let baseName = base.first { $0.name.lowercased() == key }?.name
        let mineName = mine.first { $0.name.lowercased() == key }?.name
        let theirsName = theirs.first { $0.name.lowercased() == key }?.name
        return mergeElement(base: baseName, mine: mineName, theirs: theirsName, whenBothChanged: pick)
    }

    private static func mergedFrame(_ base: BoardFrame, _ mine: BoardFrame, _ theirs: BoardFrame) -> BoardFrame {
        var merged = base
        merged.label = pick(base.label, mine.label, theirs.label)
        merged.rect = pick(base.rect, mine.rect, theirs.rect)
        return merged
    }

    // MARK: - Notes: identity is the text, a multiset — every decode mints fresh ids

    /// Every text's instances, reconciled group by group; see `mergedNoteGroup`.
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

    /// One text's instances, reconciled as a multiset. Each of base's notes is paired to its
    /// counterpart on each side by `pairToBase` — exact position first, so a plain, unmoved
    /// duplicate is never mistaken for the one that moved, then whatever is left over, in file
    /// order — and each pair is reconciled by the one merge rule: mine unchanged → theirs
    /// (deleted or not); theirs unchanged → mine (deleted or not); otherwise mine's presence or
    /// absence wins outright, same as a component field.
    ///
    /// That last case is what makes an edit survive a same-moment identity change: a note mine
    /// only moved, but that theirs' retext deleted *by identity* (its old text has no note left
    /// in this group), keeps mine's move — theirs' deletion loses to mine's real edit. Theirs'
    /// retexted note still arrives too, as its own group's addition; the two edits are never
    /// merged into one note, only both kept.
    ///
    /// Whatever in mine or theirs a pairing never claims is that side's own addition, kept in
    /// that side's order — theirs' first, then mine's.
    private static func mergedNoteGroup(_ base: [BoardNote], _ mine: [BoardNote], _ theirs: [BoardNote]) -> [BoardNote] {
        let minePairing = pairToBase(base: base, other: mine, position: { $0.at })
        let theirsPairing = pairToBase(base: base, other: theirs, position: { $0.at })
        var group: [BoardNote] = []
        for index in base.indices {
            if let note = mergeNoteElement(base: base[index], mine: minePairing.paired[index], theirs: theirsPairing.paired[index]) {
                group.append(note)
            }
        }
        group += theirsPairing.added
        group += minePairing.added
        return group
    }

    /// The one merge rule, on a single note matched to its base counterpart by position — never
    /// by whole-note equality, since a note's id is minted fresh on every decode, so two copies of
    /// "the same" note are never `==`. A note surviving in all three takes `at` by `pick` and
    /// keeps mine's id.
    private static func mergeNoteElement(base: BoardNote, mine: BoardNote?, theirs: BoardNote?) -> BoardNote? {
        if mine?.at == base.at { return theirs }
        if theirs?.at == base.at { return mine }
        guard let mine else { return nil }
        guard let theirs else { return mine }
        return BoardNote(id: mine.id, text: mine.text, at: pick(base.at, mine.at, theirs.at))
    }

    /// Distinct texts, in theirs' order, then mine-only additions in mine's order.
    private static func orderedTexts(theirs: [String], mine: [String]) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for text in theirs + mine where seen.insert(text).inserted { order.append(text) }
        return order
    }

    /// Pairs each of `base`'s elements, by index, to its counterpart in `other`: first by an exact
    /// match on `position` (each `other` element claimed at most once), then, for base indices and
    /// `other` elements still unclaimed after that, in order. Whatever in `other` no pairing
    /// claims is `other`'s own addition, in `other`'s order.
    ///
    /// Shared by notes (grouped by `.text`) and texts (grouped by `(text, style)`): both mint a
    /// fresh id on every decode, so position, not identity, is the only thing left to pair on.
    private static func pairToBase<T, P: Equatable>(
        base: [T], other: [T], position: (T) -> P
    ) -> (paired: [T?], added: [T]) {
        var pool: [T?] = other
        var paired: [T?] = Array(repeating: nil, count: base.count)
        var unresolved: [Int] = []
        for (index, item) in base.enumerated() {
            if let poolIndex = pool.firstIndex(where: { $0.map(position) == position(item) }) {
                paired[index] = pool[poolIndex]
                pool[poolIndex] = nil
            } else {
                unresolved.append(index)
            }
        }
        var leftover = pool.compactMap { $0 }
        for index in unresolved where !leftover.isEmpty {
            paired[index] = leftover.removeFirst()
        }
        return (paired, leftover)
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

    /// The same reconciliation as `mergedNoteGroup` — including the "mine's edit outlives theirs'
    /// same-moment retext" case — matched to base by position too, but a surviving pair also
    /// takes `width` and `extras` by `pick`, alongside `at`.
    private static func mergedTextGroup(_ base: [BoardText], _ mine: [BoardText], _ theirs: [BoardText]) -> [BoardText] {
        let minePairing = pairToBase(base: base, other: mine, position: { $0.at })
        let theirsPairing = pairToBase(base: base, other: theirs, position: { $0.at })
        var group: [BoardText] = []
        for index in base.indices {
            if let text = mergeTextElement(base: base[index], mine: minePairing.paired[index], theirs: theirsPairing.paired[index]) {
                group.append(text)
            }
        }
        group += theirsPairing.added
        group += minePairing.added
        return group
    }

    /// The one merge rule, on a single text matched to its base counterpart by position — never
    /// by whole-text equality, for the same reason as a note: a fresh id every decode.
    private static func mergeTextElement(base: BoardText, mine: BoardText?, theirs: BoardText?) -> BoardText? {
        if mine?.at == base.at { return theirs }
        if theirs?.at == base.at { return mine }
        guard let mine else { return nil }
        guard let theirs else { return mine }
        var merged = BoardText(
            id: mine.id, text: mine.text, style: mine.style,
            at: pick(base.at, mine.at, theirs.at),
            width: pick(base.width, mine.width, theirs.width))
        merged.extras = pick(base.extras, mine.extras, theirs.extras)
        return merged
    }
}
