import Foundation

/// Everything the board does, minus the drawing: the map, what linkC found running, the
/// selection and tool, undo, and the one pending write. The canvas holds no rules of its own.
@MainActor
@Observable
public final class BoardModel {
    public enum State: Equatable, Sendable {
        /// The project has no map, and nobody has started one.
        case empty
        case loaded
        /// The file could not be read. Nothing is edited or written while this holds.
        case failed(String)
    }

    public enum Tool: Equatable, Sendable {
        case select
        case component(ComponentKind)
        case arrow
        case frame
        case note
        case text
    }

    public struct ArrowKey: Hashable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public enum Element: Hashable, Sendable {
        case component(String)
        case frame(String)
        case note(UUID)
        case text(UUID)
        case arrow(ArrowKey)
    }

    /// What an outside change — an agent, git — just did to the map, for a glow.
    public struct OutsideChange: Equatable, Sendable {
        public let id: UUID
        public let elements: Set<Element>
    }

    public static let undoLimit = 100
    public nonisolated static let localDocker = "Local docker"
    nonisolated static let noRoomInLocalDocker = "No room left in Local docker — the new component is outside it; drag it in or make room."

    public private(set) var state: State = .empty
    public internal(set) var map: BoardMap = .empty
    public private(set) var statuses: [String: ComponentStatus] = [:]
    public private(set) var suggestions: [MapSuggestion] = []
    public private(set) var routes: [ArrowKey: BoardRoute] = [:]
    /// Where each labelled arrow's pill goes; kept in step with `routes`, the same recompute.
    public private(set) var labelRects: [ArrowKey: BoardRect] = [:]
    /// One route per foreign key whose table and referenced table are both on the board and
    /// placed; kept in step with `routes`, the same recompute.
    public private(set) var foreignKeyRoutes: [BoardForeignKey: BoardRoute] = [:]
    /// A 40 pt stub for a foreign key whose referenced table or column isn't on the board (or
    /// isn't placed). `foreignKeyRoutes` and this partition every key `BoardForeignKey.all(in:)`
    /// lists for a placed source table — see `BoardRouter.foreignKeyRoutes`/`foreignKeyStubs`.
    public private(set) var foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)] = [:]
    public var selection: Set<Element> = []
    public var tool: Tool = .select
    /// The last edit linkC would not make, and why. Cleared by the next edit that lands.
    public private(set) var refusal: String?
    /// A save that did not stick. The board stays editable; the next edit or `saveNow` retries.
    public private(set) var writeFailure: String?
    /// The file watcher couldn't start. The board is otherwise fine — editable, just not live —
    /// so this is never read as a save failure, and a save landing has nothing to do with it.
    public private(set) var liveUpdatesOff: String?
    /// The file changed underneath the board. Set only when a save collides twice running — the
    /// last resort; see `write()`.
    public private(set) var changedOnDisk = false
    /// What the last `diskChanged()` actually changed on the map — new each time, for a glow.
    public private(set) var outsideChange: OutsideChange?

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool {
        map.components.isEmpty && map.frames.isEmpty && map.notes.isEmpty && map.texts.isEmpty
    }
    public var fileURL: URL { store.fileURL }

    @ObservationIgnored private let store: BoardMapStore
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var generation = 0
    /// A separate counter from `generation` — writes and routing race independently, and a route
    /// recompute must never be skipped or delayed by an unrelated write in flight, nor vice versa.
    @ObservationIgnored private var routingGeneration = 0
    /// The detached task doing the current recompute's work, cancelled the moment a newer one
    /// starts — a superseded recompute stops rather than racing to a result that would be
    /// dropped anyway. Internal, not private, so a test can capture and assert on the handle.
    @ObservationIgnored var routingTask: Task<(
        routes: [ArrowKey: BoardRoute], labelRects: [ArrowKey: BoardRect],
        foreignKeyRoutes: [BoardForeignKey: BoardRoute], foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)]
    )?, Never>?
    @ObservationIgnored private var hasUnwrittenEdits = false
    /// Whether `read()` has ever run — `load()`'s very first call has no "before" map worth
    /// taking a real change on disk against, so it always reads in full regardless of state.
    @ObservationIgnored private var hasLoadedOnce = false
    /// Exactly what the file held when last read or written — what a save must still find.
    @ObservationIgnored private var diskBytes: Data?
    /// The decoded map of `diskBytes` — what `BoardMerge` calls `base`. Set wherever `diskBytes`
    /// is: `read`, `write`, `diskChanged`.
    @ObservationIgnored private var baseMap: BoardMap = .empty
    @ObservationIgnored private var undoStack: [BoardMap] = []
    @ObservationIgnored private var redoStack: [BoardMap] = []
    @ObservationIgnored private var lastDiscovered: [DiscoveredThing] = []

    public init(
        store: BoardMapStore,
        settle: Duration = .milliseconds(600),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.store = store
        self.settle = settle
        self.sleep = sleep
    }

    // MARK: - Lifecycle

    /// Reads the file. Never silently discards edits not yet written — a pending edit takes the
    /// same merging path `diskChanged()` already takes, exactly as if the watcher had fired
    /// instead; `reload()` is the deliberate way to drop a pending edit instead. When the bytes on
    /// disk are exactly what they were last time — reappearing after a tab switch, say — the
    /// map, undo, redo and selection are left exactly as they are.
    ///
    /// Past the first load, on a healthy, unlocked board, a real change on disk found this way is
    /// taken exactly as `diskChanged()` takes one — as one undo step, with `outsideChange` set —
    /// a reappear is no different from the watcher having fired while the Board was open. The
    /// very first load, a load after `.failed`, and `reload()` are always a full read instead:
    /// the first load has no "before" map worth remembering, and `.failed` or `changedOnDisk`
    /// must never find the bytes unchanged and leave the board stuck — only "Try again"
    /// (`reload()`) and Reload are the deliberate way out of those.
    public func load() {
        if hasLoadedOnce, canEdit {
            diskChanged()
            return
        }
        // A locked board holding an edit not yet written keeps it: a full read here would wipe
        // the map while the edit still counts as pending, and the next merge would then read
        // that wiped map as "mine deleted everything" and write it. Only Reload drops it.
        guard !hasUnwrittenEdits else { return }
        read(keepingAnUnchangedMap: true)
    }

    /// Drops any unwritten edits and reads the file again — the way out of `changedOnDisk` and
    /// of a failed read. Always a full read, never the unchanged-bytes shortcut.
    public func reload() {
        generation += 1
        hasUnwrittenEdits = false
        read(keepingAnUnchangedMap: false)
    }

    private func read(keepingAnUnchangedMap: Bool) {
        hasLoadedOnce = true
        let canKeepEverything: Bool
        switch state {
        case .loaded, .empty: canKeepEverything = keepingAnUnchangedMap && !changedOnDisk
        case .failed: canKeepEverything = false
        }
        do {
            if let loaded = try store.load() {
                guard !canKeepEverything || loaded.bytes != diskBytes else { return }
                map = loaded.map
                diskBytes = loaded.bytes
                baseMap = loaded.map
                state = .loaded
            } else {
                guard !canKeepEverything || diskBytes != nil else { return }
                map = .empty
                diskBytes = nil
                baseMap = .empty
                state = .empty
            }
        } catch {
            map = .empty
            state = .failed(message(for: error))
        }
        changedOnDisk = false
        undoStack.removeAll()
        redoStack.removeAll()
        selection = []
        mapLoaded()
    }

    /// Starts a map on a project with none. Writes nothing: the first edit creates the file.
    public func startMap() {
        guard state == .empty else { return }
        state = .loaded
    }

    /// Compares the map with what linkC found running. Never writes.
    public func reconcile(with discovered: [DiscoveredThing]) {
        lastDiscovered = discovered
        let result = BoardReconciler.reconcile(map: map, discovered: discovered)
        statuses = result.statuses
        suggestions = result.suggestions
    }

    /// The file watcher's entry point: the file changed outside linkC. Takes the new map as one
    /// undo step, or — when there is an edit not yet written — merges it with that edit through
    /// `BoardMerge`, keeping the pending write, which now saves the merge.
    public func diskChanged() {
        // Raw bytes first, undecoded — a decode is only worth doing once they actually differ
        // from what's already known (or the board doesn't trust what it knows, being `.failed`).
        let bytes: Data?
        do {
            bytes = try store.currentBytes()
        } catch {
            state = .failed(message(for: error))
            return
        }
        // The own-write guard only means anything while the board still trusts `diskBytes` as
        // the last good bytes it read. A `.failed` board doesn't: the bad read that got it there
        // never updated `diskBytes`, so the *exact* old good bytes coming back — `git merge
        // --abort` restoring them, say — would otherwise look exactly like "nothing changed" and
        // leave the board stuck, instead of being taken as the fresh, readable file it now is.
        var isFailed: Bool { if case .failed = state { return true } else { return false } }
        guard isFailed || bytes != diskBytes else { return }   // the Board's own write; nothing outside changed

        let theirs: BoardMap
        do {
            theirs = try bytes.map { try BoardMap.decode($0) } ?? .empty
        } catch {
            state = .failed(message(for: error))
            return
        }

        let before = map
        // `BoardMerge.merge` alone mints a fresh id for any note or text that neither side
        // touched — it takes theirs' just-redecoded copy, which decodes with a new id every
        // time, same as the plain-replace path below always needed `carryingIds` for. Run it on
        // the merge's result too, or an edit pending at the same moment an outside change lands
        // loses that note's or text's id (and any selection or open editor keyed by it) for no
        // real reason.
        let rawReplacement = hasUnwrittenEdits ? BoardMerge.merge(base: baseMap, mine: map, theirs: theirs) : theirs
        map = Self.laidOut(Self.carryingIds(from: before, into: rawReplacement))
        diskBytes = bytes
        baseMap = theirs

        // A reformat with no real change to the map — same content, different bytes — must not
        // mint a phantom undo step or glow; `diskBytes`/`baseMap` above still move, so a further,
        // real outside change merges against what's actually on disk now.
        let mapReallyChanged = map != before

        let fileExists = bytes != nil
        switch state {
        case .failed:
            // A fresh start, exactly as a load is: nothing stale carries over, and this is not
            // an edit to undo back out of.
            state = fileExists ? .loaded : .empty
            undoStack.removeAll()
            redoStack.removeAll()
            selection = []
        case .empty:
            // Past the guard above, the only way to reach `.empty` here is a file that did not
            // exist before now existing.
            state = .loaded
        case .loaded:
            if !fileExists && !hasUnwrittenEdits {
                state = .empty
            } else if mapReallyChanged {
                undoStack.append(before)
                if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
                redoStack.removeAll()
            }
        }

        if mapReallyChanged {
            outsideChange = OutsideChange(id: UUID(), elements: Self.changed(from: before, to: map))
        }
        selection = selection.filter(exists)
        recomputeRoutes()
        reconcile(with: lastDiscovered)
        if hasUnwrittenEdits { scheduleWrite() }
    }

    /// Writes now rather than after the settle — for the board closing. Still writes only when
    /// something changed.
    public func saveNow() {
        generation += 1
        write()
    }

    /// The file watcher couldn't start. The board stays exactly as it loaded — editable, just not
    /// live — and says so on its own quiet banner, never the save-failure one.
    public func liveUpdatesFailed(_ message: String) {
        liveUpdatesOff = "Live updates are off: \(message)"
    }

    /// The watcher started (or restarted) successfully — called on that success path. Clears
    /// whatever earlier failure's banner was still showing, since live updates are working again.
    public func liveUpdatesStarted() {
        liveUpdatesOff = nil
    }

    // MARK: - Undo

    public func undo() {
        guard canEdit, let previous = undoStack.popLast() else { return }
        redoStack.append(map)
        map = previous
        refusal = nil
        afterMapChange()
    }

    public func redo() {
        guard canEdit, let next = redoStack.popLast() else { return }
        undoStack.append(map)
        map = next
        refusal = nil
        afterMapChange()
    }

    // MARK: - Content edits

    public func setSystem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { map in
            guard (map.system ?? "") != trimmed else { return false }
            map.system = trimmed.isEmpty ? nil : trimmed
            return true
        }
    }

    /// A new component, planned, centred where it was placed and slid clear of anything there.
    @discardableResult
    public func addComponent(kind: ComponentKind, at point: BoardPoint) -> String? {
        var added: String?
        edit { map in
            let name = Self.uniqueName("new-\(kind.raw)", taken: Set(map.components.map { $0.name.lowercased() }))
            let probe = BoardComponent(name: name, kind: kind, at: point)
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(of: probe)!.snapped,
                otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
            let place = BoardGeometry.frame(containing: rect, frames: map.frames)?.label ?? BoardMap.notPlaced
            map.components.append(BoardComponent(name: name, kind: kind, planned: true, place: place, at: rect.origin))
            added = name
            return true
        }
        if let added { selection = [.component(added)] }
        return added
    }

    @discardableResult
    public func addNote(at point: BoardPoint) -> UUID? {
        var added: UUID?
        edit { map in
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(ofNoteAt: point).snapped,
                otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
            let note = BoardNote(text: "", at: rect.origin)
            map.notes.append(note)
            added = note.id
            return true
        }
        if let added { selection = [.note(added)] }
        return added
    }

    @discardableResult
    public func addText(at point: BoardPoint, style: BoardTextStyle, text: String, width: Int) -> UUID? {
        var added: UUID?
        let width = Self.roundedUpToGrid(width)
        edit { map in
            let probe = BoardText(text: text, style: style, at: point, width: width)
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(of: probe).snapped,
                otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
            let placed = BoardText(text: text, style: style, at: rect.origin, width: width)
            map.texts.append(placed)
            added = placed.id
            return true
        }
        if let added { selection = [.text(added)] }
        return added
    }

    /// A new frame where it was drawn. Anything wholly inside becomes its own; a frame that would
    /// cross another frame or cut through anything is refused.
    @discardableResult
    public func addFrame(_ drawn: BoardRect) -> String? {
        var added: String?
        edit { map in
            var rect = drawn.snapped
            rect.w = max(rect.w, BoardGeometry.frameMinSize.x)
            rect.h = max(rect.h, BoardGeometry.frameMinSize.y)
            if Self.frameRects(map, excluding: []).contains(where: { $0.intersects(rect) }) {
                return refuse("A frame can't overlap another frame — draw it in empty space.")
            }
            let interior = BoardGeometry.interior(of: rect)
            if Self.elementRects(map, excluding: []).contains(where: { $0.intersects(rect) && !interior.contains($0) }) {
                return refuse("A frame can't cut through things — draw it around them, or in empty space.")
            }
            let label = Self.uniqueName("Frame", taken: Set(map.frames.map { $0.label.lowercased() }).union([BoardMap.notPlaced.lowercased()]), separator: " ")
            map.frames.append(BoardFrame(label: label, rect: rect))
            for index in map.components.indices {
                if let rect = BoardGeometry.rect(of: map.components[index]), interior.contains(rect) {
                    map.components[index].place = label
                }
            }
            added = label
            return true
        }
        if let added { selection = [.frame(added)] }
        return added
    }

    /// Takes the editable fields from `updated`: name, kind, what it does, how it is reached, where
    /// it runs, whether it is planned. Its place, position and arrows are the drawing's. Returns
    /// false only when the edit was refused — the inspector stays open on false.
    ///
    /// A thin shim over `updateComponent(_:fields:rename:)`: every field is passed as an explicit
    /// "set to this" value — a `nil` `does`/`reachedBy`/`runs` becomes `""`, which that overload
    /// reads the same way, as "clear it" — and the name is always passed to `rename`, since this
    /// overload has no notion of "leave a field alone".
    @discardableResult
    public func updateComponent(_ name: String, to updated: BoardComponent) -> Bool {
        let fields = BoardComponentFields(
            kind: updated.kind, does: updated.does ?? "", reachedBy: updated.reachedBy ?? "",
            runs: updated.runs ?? "", planned: updated.planned)
        return updateComponent(name, fields: fields, rename: updated.name)
    }

    /// Changes only the fields `fields` actually carries — `nil` leaves that field exactly as it
    /// is, `""` clears `does`, `reachedBy` or `runs` — and renames it only when `rename` is given,
    /// with the same checks `updateComponent(_:to:)` always ran: a blank name is refused, and so
    /// is a clash with another component. The one implementation of the rename and uniqueness
    /// rules; `updateComponent(_:to:)` is the other caller. Returns false only when refused.
    ///
    /// This is what lets an inspector card open on a stale, opened-time copy commit safely: with
    /// `rename: nil` and only the fields the user actually touched, whatever changed on the same
    /// component in the meantime — an agent's edit, say — is left exactly as it now is.
    @discardableResult
    public func updateComponent(_ name: String, fields: BoardComponentFields, rename newName: String? = nil) -> Bool {
        var refused = false
        edit { map in
            guard let index = Self.index(of: name, in: map) else { return false }
            let old = map.components[index]
            var next = old
            if let kind = fields.kind { next.kind = kind }
            if let does = fields.does { next.does = does.isEmpty ? nil : does }
            if let reachedBy = fields.reachedBy { next.reachedBy = reachedBy.isEmpty ? nil : reachedBy }
            if let runs = fields.runs { next.runs = runs.isEmpty ? nil : runs }
            if let planned = fields.planned { next.planned = planned }

            var finalName = name
            if let newName {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    refused = true
                    return refuse("A component needs a name.")
                }
                if trimmed.lowercased() != name.lowercased(),
                   map.components.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                    refused = true
                    return refuse("This map already has a component named \"\(trimmed)\".")
                }
                next.name = trimmed
                finalName = trimmed
            }

            guard next != old else { return false }
            map.components[index] = next
            if finalName != name {
                for other in map.components.indices {
                    if let arrow = map.components[other].uses.removeValue(forKey: name) {
                        map.components[other].uses[finalName] = arrow
                    }
                }
                // Carried here, before `afterMapChange` filters the selection against the renamed
                // map — done afterward, the old name would already be gone and filtered out.
                selection = Set(selection.map { $0 == .component(name) ? .component(finalName) : $0 })
            }
            return true
        }
        return !refused
    }

    /// Relabels a frame and moves its components to the new place. Returns false only when refused.
    @discardableResult
    public func renameFrame(_ label: String, to newLabel: String) -> Bool {
        var refused = false
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { map in
            guard let index = map.frames.firstIndex(where: { $0.label == label }) else { return false }
            guard !trimmed.isEmpty else {
                refused = true
                return refuse("A frame needs a label.")
            }
            guard trimmed.lowercased() != BoardMap.notPlaced.lowercased() else {
                refused = true
                return refuse("\"\(BoardMap.notPlaced)\" is reserved for things outside every frame.")
            }
            if trimmed.lowercased() != label.lowercased(),
               map.frames.contains(where: { $0.label.lowercased() == trimmed.lowercased() }) {
                refused = true
                return refuse("This map already has a frame labelled \"\(trimmed)\".")
            }
            guard trimmed != label else { return false }
            map.frames[index].label = trimmed
            for other in map.components.indices where map.components[other].place == label {
                map.components[other].place = trimmed
            }
            // Carried here, before `afterMapChange` filters the selection against the renamed map.
            selection = Set(selection.map { $0 == .frame(label) ? .frame(trimmed) : $0 })
            return true
        }
        return !refused
    }

    public func setNoteText(_ id: UUID, to text: String) {
        edit { map in
            guard let index = map.notes.firstIndex(where: { $0.id == id }), map.notes[index].text != text else { return false }
            map.notes[index].text = text
            return true
        }
    }

    /// New words for a text. Emptied of words, the text goes away. A wider text runs the same
    /// drop step a move does, so a rename never lands it on top of what is beside it.
    public func setText(_ id: UUID, to text: String, width: Int) {
        let width = Self.roundedUpToGrid(width)
        edit { map in
            guard let index = map.texts.firstIndex(where: { $0.id == id }) else { return false }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                map.texts.remove(at: index)
                return true
            }
            guard map.texts[index].text != text || map.texts[index].width != width else { return false }
            map.texts[index].text = text
            map.texts[index].width = width
            let landed = BoardGeometry.elementDrop(
                BoardGeometry.rect(of: map.texts[index]).snapped,
                otherElements: Self.elementRects(map, excluding: [.text(id)]),
                frames: Self.frameRects(map, excluding: []))
            map.texts[index].at = landed.origin
            return true
        }
    }

    @discardableResult
    public func addArrow(from source: String, to target: String) -> Bool {
        var landed = false
        edit { map in
            guard let sourceIndex = Self.index(of: source, in: map), let targetIndex = Self.index(of: target, in: map) else { return false }
            guard source.lowercased() != target.lowercased() else { return refuse("An arrow needs two different components.") }
            let realTarget = map.components[targetIndex].name
            guard !map.components[sourceIndex].uses.keys.contains(where: { $0.lowercased() == realTarget.lowercased() }) else {
                return refuse("\(source) already uses \(realTarget) — double-click that arrow to change its label.")
            }
            map.components[sourceIndex].uses[realTarget] = BoardArrow(style: BoardArrowStyle.default(from: map.components[sourceIndex].kind))
            landed = true
            return true
        }
        return landed
    }

    /// Sets an arrow's label, style and bits together, as one undo step — so one edit in the
    /// Arrow editor takes one undo to take back, not two. Refuses bits outside 1…4096 or bits on
    /// a non-bus style; a no-op when nothing would change.
    public func setArrow(_ arrow: ArrowKey, label: String, style: BoardArrowStyle, bits: Int?) {
        edit { map in
            guard let index = Self.index(of: arrow.from, in: map), let existing = map.components[index].uses[arrow.to] else { return false }
            if let bits {
                guard style == .bus else { return refuse("\"bits\" needs style \"bus\".") }
                guard (1...4096).contains(bits) else { return refuse("\"bits\" must be between 1 and 4096.") }
            }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing.label != trimmed || existing.style != style || existing.bits != bits else { return false }
            map.components[index].uses[arrow.to] = BoardArrow(label: trimmed, style: style, bits: bits)
            return true
        }
    }

    /// Deleting a component takes its arrows with it. Deleting a frame keeps its components; they
    /// become not placed.
    public func delete(_ elements: Set<Element>) {
        guard !elements.isEmpty else { return }
        edit { map in
            var changed = false
            for element in elements {
                switch element {
                case .component(let name):
                    guard let index = Self.index(of: name, in: map) else { continue }
                    map.components.remove(at: index)
                    for other in map.components.indices { map.components[other].uses.removeValue(forKey: name) }
                    changed = true
                case .frame(let label):
                    guard let index = map.frames.firstIndex(where: { $0.label == label }) else { continue }
                    map.frames.remove(at: index)
                    for other in map.components.indices where map.components[other].place == label {
                        map.components[other].place = BoardMap.notPlaced
                    }
                    changed = true
                case .note(let id):
                    if let index = map.notes.firstIndex(where: { $0.id == id }) { map.notes.remove(at: index); changed = true }
                case .text(let id):
                    if let index = map.texts.firstIndex(where: { $0.id == id }) { map.texts.remove(at: index); changed = true }
                case .arrow(let arrow):
                    if let index = Self.index(of: arrow.from, in: map), map.components[index].uses.removeValue(forKey: arrow.to) != nil {
                        changed = true
                    }
                }
            }
            return changed
        }
        selection.subtract(elements)
    }

    /// One running thing onto the map, inside the "Local docker" frame — created, or grown by a
    /// row, when there is no room. Already named on the map, it adds nothing and is not an edit.
    public func addSuggestion(_ suggestion: MapSuggestion) {
        var unplaced = false
        edit { map in
            let result = Self.place([suggestion], into: &map)
            unplaced = result.unplaced
            return result.added
        }
        if unplaced { refusal = Self.noRoomInLocalDocker }
    }

    /// Everything running onto the map at once, in one "Local docker" frame, as one undo step.
    /// Whatever is already named on the map adds nothing; an empty result is not an edit.
    public func addAllRunning() {
        let all = suggestions
        guard !all.isEmpty else { return }
        var unplaced = false
        edit { map in
            let result = Self.place(all, into: &map)
            unplaced = result.unplaced
            return result.added
        }
        if unplaced { refusal = Self.noRoomInLocalDocker }
    }

    /// Rearranges the whole map by the flow of its arrows — `BoardLayout.arranged`, as one undo
    /// step. Refused while locked, as every edit is; a map already arranged changes nothing, so
    /// it is not an edit and leaves no undo step behind.
    public func tidyUp() {
        edit { map in
            let arranged = BoardLayout.arranged(map)
            guard arranged != map else { return false }
            map = arranged
            return true
        }
    }

    // MARK: - Hooks the spatial edits share

    var canEdit: Bool {
        if case .failed = state { return false }
        return !changedOnDisk
    }

    /// Whether the board currently refuses edits — `canEdit` itself, for the app: the Tidy up
    /// button disables on this.
    public var isLocked: Bool { !canEdit }

    /// Every edit: refused outright while the board is locked; otherwise applied to a copy, and —
    /// when it changed something — recorded for undo and followed by one scheduled write.
    func edit(_ change: (inout BoardMap) -> Bool) {
        guard canEdit else { return }
        var next = map
        guard change(&next) else { return }
        undoStack.append(map)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        map = next
        refusal = nil
        afterMapChange()
    }

    /// Records why an edit was refused; returns false so the edit changes nothing.
    func refuse(_ message: String) -> Bool {
        refusal = message
        return false
    }

    func afterMapChange() {
        if state == .empty { state = .loaded }
        hasUnwrittenEdits = true
        selection = selection.filter(exists)
        recomputeRoutes()
        reconcile(with: lastDiscovered)
        scheduleWrite()
    }

    /// Called after every load: lays out whatever the file left without a place on the board. In
    /// memory only — this is not an edit, so it writes nothing.
    func mapLoaded() {
        map = Self.laidOut(map)
        recomputeRoutes()
        reconcile(with: lastDiscovered)
    }

    /// Routes every arrow and places every label off the main actor, from a `Sendable` snapshot
    /// of `map` — `BoardRouter` and `BoardLabels` are pure and never touch the model themselves.
    /// The detached task doing that work is cancelled the moment a newer recompute starts, so a
    /// superseded one stops rather than racing to a result thrown away anyway; the result also
    /// lands back on the main actor only if no newer recompute has since started, by a generation
    /// counter of its own, separate from `generation` (writes) — a write in flight must never
    /// skip or delay a route recompute, nor the other way around. Internal, not private, so a
    /// test can await the returned `Task`, or capture and assert on `routingTask`, instead of
    /// racing the recompute.
    @discardableResult
    func recomputeRoutes() -> Task<Void, Never> {
        routingGeneration += 1
        let scheduled = routingGeneration
        let snapshot = map
        routingTask?.cancel()
        let detached = Task.detached {
            Self.routesAndLabels(for: snapshot)
        }
        routingTask = detached
        return Task { @MainActor [weak self] in
            guard let result = await detached.value, !Task.isCancelled else { return }
            guard let self, self.routingGeneration == scheduled else { return }
            self.routes = result.routes
            self.labelRects = result.labelRects
            self.foreignKeyRoutes = result.foreignKeyRoutes
            self.foreignKeyStubs = result.foreignKeyStubs
        }
    }

    /// The pure computation `recomputeRoutes()` runs off the main actor: every arrow's route, then
    /// every labelled arrow's pill, then every foreign key's own route or stub — all from the same
    /// map. Routing is the pricier of the phases (measured at 7–43 ms; labelling at 0.3 ms) and
    /// checks `isCancelled` itself, between arrows; `isCancelled` is checked again once routing
    /// returns, before the labelling pass, and a third time before the foreign-key pass, in case
    /// cancellation lands in one of the gaps — cheap insurance either way against doing work for a
    /// result about to be dropped. Internal, not private, and `isCancelled` is injectable, so a
    /// test can drive it deterministically instead of racing real `Task` cancellation.
    nonisolated static func routesAndLabels(
        for map: BoardMap, isCancelled: () -> Bool = { Task.isCancelled }
    ) -> (
        routes: [ArrowKey: BoardRoute], labelRects: [ArrowKey: BoardRect],
        foreignKeyRoutes: [BoardForeignKey: BoardRoute], foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)]
    )? {
        let routes = BoardRouter.routes(for: map)
        guard !isCancelled() else { return nil }
        // The placer's text is the arrow's full pill — label and width combined, or width alone
        // for an unlabelled bus — never the router's own bundling label, which stays `arrow.label`
        // so bundling is unaffected by what the pill happens to show.
        var labelOf: [ArrowKey: String] = [:]
        for component in map.components {
            for (target, arrow) in component.uses {
                guard let pill = BoardLabels.pillText(for: arrow) else { continue }
                labelOf[ArrowKey(from: component.name, to: target)] = pill
            }
        }
        let labelRects = BoardLabels.placed(routes: routes, labels: labelOf, obstacles: BoardLabels.obstacles(for: map))
        guard !isCancelled() else { return nil }
        return (routes, labelRects, BoardRouter.foreignKeyRoutes(for: map), BoardRouter.foreignKeyStubs(for: map))
    }

    nonisolated static func elementRects(_ map: BoardMap, excluding excluded: Set<Element>) -> [BoardRect] {
        var rects: [BoardRect] = []
        for component in map.components where !excluded.contains(.component(component.name)) {
            if let rect = BoardGeometry.rect(of: component) { rects.append(rect) }
        }
        for note in map.notes where !excluded.contains(.note(note.id)) {
            if let at = note.at { rects.append(BoardGeometry.rect(ofNoteAt: at)) }
        }
        for text in map.texts where !excluded.contains(.text(text.id)) {
            rects.append(BoardGeometry.rect(of: text))
        }
        return rects
    }

    nonisolated static func frameRects(_ map: BoardMap, excluding excluded: Set<String>) -> [BoardRect] {
        map.frames.filter { !excluded.contains($0.label) }.compactMap(\.rect)
    }

    /// Every component, note or text whose box intersects `area` — a marquee's own pick. A
    /// component is skipped when `visibleParts` is given and doesn't name it, so a marquee drawn
    /// while Focus is on can never pick what Focus is hiding; `nil` picks every component, as
    /// when Focus is off. Notes and texts are always eligible — Focus never hides those.
    public nonisolated static func marqueePick(in area: BoardRect, map: BoardMap, visibleParts: Set<String>?) -> Set<Element> {
        var picked: Set<Element> = []
        for component in map.components {
            guard visibleParts?.contains(component.name) ?? true else { continue }
            guard let rect = BoardGeometry.rect(of: component), rect.intersects(area) else { continue }
            picked.insert(.component(component.name))
        }
        for note in map.notes {
            guard let at = note.at, BoardGeometry.rect(ofNoteAt: at).intersects(area) else { continue }
            picked.insert(.note(note.id))
        }
        for text in map.texts where BoardGeometry.rect(of: text).intersects(area) {
            picked.insert(.text(text.id))
        }
        return picked
    }

    nonisolated static func index(of name: String, in map: BoardMap) -> Int? {
        map.components.firstIndex { $0.name.lowercased() == name.lowercased() }
    }

    nonisolated static func uniqueName(_ base: String, taken: Set<String>, separator: String = "-") -> String {
        var name = base
        var suffix = 2
        while taken.contains(name.lowercased()) {
            name = "\(base)\(separator)\(suffix)"
            suffix += 1
        }
        return name
    }

    /// A text's width, always rounded up to the grid before it is stored — never down, so it
    /// stays wide enough for its words, and never left as-is, so the collision check (which
    /// rounds too) checks the exact number that ends up on the map.
    nonisolated static func roundedUpToGrid(_ width: Int) -> Int {
        let step = BoardPoint.grid
        return ((width + step - 1) / step) * step
    }

    /// Adds `component` inside the frame labelled `label` — grown to fit when there is no room
    /// — and returns whether it landed there. When the frame has no room and cannot grow, the
    /// component is filed outside it instead: under whichever frame its fallback spot's centre
    /// lands in, or `BoardMap.notPlaced` — the containment rule any overflow follows.
    @discardableResult
    nonisolated static func placeComponent(_ component: BoardComponent, inFrame label: String, into map: inout BoardMap) -> Bool {
        guard let frameIndex = map.frames.firstIndex(where: { $0.label == label }) else {
            preconditionFailure("placeComponent: no frame labelled \"\(label)\"")
        }
        guard var frame = map.frames[frameIndex].rect else {
            return false
        }
        let size = BoardGeometry.size(of: component)
        // Everything already inside the frame is avoided — not just its components. A note or
        // text has no `place`, so membership is geometric: wholly inside the interior.
        let interior = BoardGeometry.interior(of: frame)
        let memberComponents = Set(map.components.filter { $0.place == label }.map(\.name))
        let memberNotes = Set(map.notes.filter { $0.at.map { interior.contains(BoardGeometry.rect(ofNoteAt: $0)) } ?? false }.map(\.id))
        let memberTexts = Set(map.texts.filter { interior.contains(BoardGeometry.rect(of: $0)) }.map(\.id))
        let members = map.components.filter { memberComponents.contains($0.name) }.compactMap(BoardGeometry.rect(of:))
            + map.notes.filter { memberNotes.contains($0.id) }.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
            + map.texts.filter { memberTexts.contains($0.id) }.map(BoardGeometry.rect(of:))
        let excluded = Set(memberComponents.map { Element.component($0) })
            .union(memberNotes.map { Element.note($0) })
            .union(memberTexts.map { Element.text($0) })
        let foreign = elementRects(map, excluding: excluded).filter { !frame.contains($0) }
        let others = frameRects(map, excluding: [label])
        let seed = BoardRect(x: frame.x + BoardGeometry.frameInset, y: frame.y + BoardGeometry.frameInset, w: size.x, h: size.y)
        var spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: members, inside: interior)
        if spot == nil, let grown = BoardGeometry.grow(frame, toFit: size, members: members, otherFrames: others, foreignElements: foreign) {
            frame = grown
            map.frames[frameIndex].rect = grown
            spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: members, inside: BoardGeometry.interior(of: grown))
        }
        let landed = spot ?? BoardGeometry.elementDrop(seed.offsetBy(dx: frame.w + 48, dy: 0),
                                                     otherElements: elementRects(map, excluding: []), frames: frameRects(map, excluding: []))
        // Overflow that lands inside another frame is filed there, as the containment rule
        // says — not blindly "Not placed" just because it did not fit in this frame.
        var placed = component
        placed.place = spot != nil ? label : (BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced)
        placed.at = landed.origin
        map.components.append(placed)
        return spot != nil
    }

    /// A new frame labelled `label`, sized `size`, dropped to the right of everything already on
    /// the board.
    nonisolated static func appendFrame(label: String, size: BoardPoint, into map: inout BoardMap) {
        let wanted = BoardRect(x: 0, y: 0, w: size.x, h: size.y).snapped
        let content = elementRects(map, excluding: []) + frameRects(map, excluding: [])
        let seedX = (content.map(\.maxX).max() ?? 0) + (content.isEmpty ? 0 : 48)
        let rect = BoardGeometry.frameDrop(wanted.offsetBy(dx: seedX, dy: 0).snapped, otherFrames: [], foreignElements: content)
        map.frames.append(BoardFrame(label: label, rect: rect))
    }

    /// `component`, placed to the right of everything on the board, overlapping nothing — filed
    /// under whichever frame its landing spot's centre falls in, or `BoardMap.notPlaced`.
    nonisolated static func placeLoose(_ component: BoardComponent, into map: inout BoardMap) {
        let size = BoardGeometry.size(of: component)
        let content = elementRects(map, excluding: []) + frameRects(map, excluding: [])
        let seed = BoardRect(x: (content.map(\.maxX).max() ?? 0) + 48, y: 0, w: size.x, h: size.y)
        let landed = BoardGeometry.elementDrop(seed, otherElements: elementRects(map, excluding: []), frames: frameRects(map, excluding: []))
        var placed = component
        placed.place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
        placed.at = landed.origin
        map.components.append(placed)
    }

    // MARK: - Internals

    private func exists(_ element: Element) -> Bool {
        switch element {
        case .component(let name): return Self.index(of: name, in: map) != nil
        case .frame(let label): return map.frames.contains { $0.label == label }
        case .note(let id): return map.notes.contains { $0.id == id }
        case .text(let id): return map.texts.contains { $0.id == id }
        case .arrow(let arrow):
            guard let index = Self.index(of: arrow.from, in: map) else { return false }
            return map.components[index].uses[arrow.to] != nil
        }
    }

    /// What `diskChanged()` just did to the map, for `outsideChange`: components new, or
    /// different by value, by name (a relabelled or new arrow included — it lives in its source
    /// component's `uses`, so a changed arrow always changes its source's value too); frames new,
    /// or different, by label; notes whose text is new. Texts carry no such signal.
    nonisolated private static func changed(from before: BoardMap, to after: BoardMap) -> Set<Element> {
        var result: Set<Element> = []

        let beforeComponents = Dictionary(before.components.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for component in after.components where beforeComponents[component.name.lowercased()] != component {
            result.insert(.component(component.name))
        }

        let beforeFrames = Dictionary(before.frames.map { ($0.label.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for frame in after.frames where beforeFrames[frame.label.lowercased()] != frame {
            result.insert(.frame(frame.label))
        }

        let beforeNoteTexts = Set(before.notes.map(\.text))
        for note in after.notes where !beforeNoteTexts.contains(note.text) {
            result.insert(.note(note.id))
        }

        return result
    }

    /// `theirs`, with any note or text that is really the same one as in `before` — matched by
    /// text (and style, for a text) and position, `BoardMerge`'s own pairing rule — keeping
    /// `before`'s id instead of the fresh one a decode always mints. Without this, an open
    /// `NoteEditor` or a selection keyed by the old id goes dead the moment an outside change
    /// that never touched that note replaces the map.
    nonisolated private static func carryingIds(from before: BoardMap, into theirs: BoardMap) -> BoardMap {
        var theirs = theirs
        theirs.notes = BoardMerge.carryingIds(from: before.notes, into: theirs.notes)
        theirs.texts = BoardMerge.carryingIds(from: before.texts, into: theirs.texts)
        return theirs
    }

    /// Puts running things on the map inside the "Local docker" frame, laid out four to a row.
    /// Reports whether anything was added — a suggestion already named on the map, or repeated
    /// within this same batch, adds nothing — and whether any addition had no room and was left
    /// outside every frame.
    private static func place(_ suggestions: [MapSuggestion], into map: inout BoardMap) -> (added: Bool, unplaced: Bool) {
        var named = Set(map.components.map { $0.name.lowercased() })
        var fresh: [MapSuggestion] = []
        for suggestion in suggestions {
            let key = suggestion.name.lowercased()
            guard !named.contains(key) else { continue }
            named.insert(key)
            fresh.append(suggestion)
        }
        guard !fresh.isEmpty else { return (added: false, unplaced: false) }
        let size = BoardGeometry.componentSize
        let gap = 16

        if !map.frames.contains(where: { $0.label == localDocker }) {
            let columns = min(4, fresh.count)
            let rows = (fresh.count + columns - 1) / columns
            let wanted = BoardPoint(
                x: max(BoardGeometry.frameMinSize.x, columns * (size.x + gap) + gap),
                y: max(BoardGeometry.frameMinSize.y, rows * (size.y + gap) + gap))
            appendFrame(label: localDocker, size: wanted, into: &map)
        }

        var unplaced = false
        for suggestion in fresh {
            let landed = placeComponent(BoardComponent(name: suggestion.name, kind: suggestion.kind), inFrame: localDocker, into: &map)
            if !landed { unplaced = true }
        }
        return (added: true, unplaced: unplaced)
    }

    private func scheduleWrite() {
        generation += 1
        let scheduled = generation
        let sleep = self.sleep
        let settle = self.settle
        Task { @MainActor [weak self] in
            await sleep(settle)
            guard let self, self.generation == scheduled else { return }
            self.write()
        }
    }

    private func write() {
        guard canEdit, hasUnwrittenEdits else { return }
        do {
            try commitSave()
        } catch BoardMapStoreError.changedOnDisk {
            // The file changed while this save was in flight. `diskChanged()` merges it with the
            // edit — still unwritten, so it still applies — instead of leaving the save refused.
            // Only a second collision right here, the file changing again under the very save
            // meant to land that merge, falls back to the lock: a last resort, not the everyday
            // case a watcher-driven `diskChanged()` already handles.
            diskChanged()
            // `diskChanged()` can itself find the file has gone unreadable and lock the board as
            // `.failed` — already the real problem, and already shown. Retrying the save on top
            // of that would only fail a second time and set `changedOnDisk` as well, compounding
            // a `.failed` board with a stale "changed on disk" lock that then outlives the
            // failure: recovering from `.failed` never clears `changedOnDisk` on its own, since
            // the two are meant to be mutually exclusive reasons the board is unhappy.
            guard canEdit else { return }
            do {
                try commitSave()
            } catch BoardMapStoreError.changedOnDisk {
                changedOnDisk = true
            } catch {
                writeFailure = message(for: error)
            }
        } catch {
            writeFailure = message(for: error)
        }
    }

    /// The save both attempts in `write()` share on success: write `map`, expecting the file
    /// still holds `diskBytes`, and record the result as the new known-good state. Throws
    /// `BoardMapStoreError.changedOnDisk` unchanged for the caller to handle.
    private func commitSave() throws {
        diskBytes = try store.save(map, expecting: diskBytes)
        baseMap = map
        hasUnwrittenEdits = false
        writeFailure = nil
    }

    private func message(for error: Error) -> String {
        if let error = error as? LinkCError { return error.localizedDescription }
        return String(describing: error)
    }
}
