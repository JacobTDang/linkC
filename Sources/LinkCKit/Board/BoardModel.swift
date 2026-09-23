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

    public static let undoLimit = 100
    public static let localDocker = "Local docker"
    static let noRoomInLocalDocker = "No room left in Local docker — the new component is outside it; drag it in or make room."

    public private(set) var state: State = .empty
    public internal(set) var map: BoardMap = .empty
    public private(set) var statuses: [String: ComponentStatus] = [:]
    public private(set) var suggestions: [MapSuggestion] = []
    public private(set) var routes: [ArrowKey: [BoardPoint]] = [:]
    public var selection: Set<Element> = []
    public var tool: Tool = .select
    /// The last edit linkC would not make, and why. Cleared by the next edit that lands.
    public private(set) var refusal: String?
    /// A save that did not stick. The board stays editable; the next edit or `saveNow` retries.
    public private(set) var writeFailure: String?
    /// The file changed underneath the board. Edits are locked until `reload()`.
    public private(set) var changedOnDisk = false

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool {
        map.components.isEmpty && map.frames.isEmpty && map.notes.isEmpty && map.texts.isEmpty
    }

    @ObservationIgnored private let store: BoardMapStore
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasUnwrittenEdits = false
    /// Exactly what the file held when last read or written — what a save must still find.
    @ObservationIgnored private var diskBytes: Data?
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

    /// Reads the file. Refuses to replace a map with edits not yet written, so a reload can never
    /// silently discard work — `reload()` is the deliberate way to do that.
    public func load() {
        guard !hasUnwrittenEdits else { return }
        do {
            if let loaded = try store.load() {
                map = loaded.map
                diskBytes = loaded.bytes
                state = .loaded
            } else {
                map = .empty
                diskBytes = nil
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

    /// Drops any unwritten edits and reads the file again — the way out of `changedOnDisk`.
    public func reload() {
        generation += 1
        hasUnwrittenEdits = false
        load()
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

    /// Writes now rather than after the settle — for the board closing. Still writes only when
    /// something changed.
    public func saveNow() {
        generation += 1
        write()
    }

    // MARK: - Undo

    public func undo() {
        guard canEdit, let previous = undoStack.popLast() else { return }
        redoStack.append(map)
        map = previous
        afterMapChange()
    }

    public func redo() {
        guard canEdit, let next = redoStack.popLast() else { return }
        undoStack.append(map)
        map = next
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
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(ofComponentAt: point).snapped,
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
                if let at = map.components[index].at, interior.contains(BoardGeometry.rect(ofComponentAt: at)) {
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
    @discardableResult
    public func updateComponent(_ name: String, to updated: BoardComponent) -> Bool {
        var refused = false
        let newName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { map in
            guard let index = Self.index(of: name, in: map) else { return false }
            guard !newName.isEmpty else {
                refused = true
                return refuse("A component needs a name.")
            }
            if newName.lowercased() != name.lowercased(),
               map.components.contains(where: { $0.name.lowercased() == newName.lowercased() }) {
                refused = true
                return refuse("This map already has a component named \"\(newName)\".")
            }
            let old = map.components[index]
            var next = old
            next.name = newName
            next.kind = updated.kind
            next.does = updated.does
            next.reachedBy = updated.reachedBy
            next.runs = updated.runs
            next.planned = updated.planned
            guard next != old else { return false }
            map.components[index] = next
            if newName != name {
                for other in map.components.indices {
                    if let label = map.components[other].uses.removeValue(forKey: name) {
                        map.components[other].uses[newName] = label
                    }
                }
                // Carried here, before `afterMapChange` filters the selection against the renamed
                // map — done afterward, the old name would already be gone and filtered out.
                selection = Set(selection.map { $0 == .component(name) ? .component(newName) : $0 })
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
            map.components[sourceIndex].uses[realTarget] = ""
            landed = true
            return true
        }
        return landed
    }

    public func setArrowLabel(_ arrow: ArrowKey, to label: String) {
        edit { map in
            guard let index = Self.index(of: arrow.from, in: map), map.components[index].uses[arrow.to] != nil else { return false }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard map.components[index].uses[arrow.to] != trimmed else { return false }
            map.components[index].uses[arrow.to] = trimmed
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

    // MARK: - Hooks the spatial edits share

    var canEdit: Bool {
        if case .failed = state { return false }
        return !changedOnDisk
    }

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

    func recomputeRoutes() {
        var rects: [String: BoardRect] = [:]
        for component in map.components {
            if let at = component.at { rects[component.name] = BoardGeometry.rect(ofComponentAt: at) }
        }
        let obstacles = Array(rects.values) + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        var next: [ArrowKey: [BoardPoint]] = [:]
        for component in map.components {
            guard let source = rects[component.name] else { continue }
            for target in component.uses.keys {
                guard let destination = rects[target] else { continue }
                next[ArrowKey(from: component.name, to: target)] = BoardGeometry.route(from: source, to: destination, obstacles: obstacles)
            }
        }
        routes = next
    }

    static func elementRects(_ map: BoardMap, excluding excluded: Set<Element>) -> [BoardRect] {
        var rects: [BoardRect] = []
        for component in map.components where !excluded.contains(.component(component.name)) {
            if let at = component.at { rects.append(BoardGeometry.rect(ofComponentAt: at)) }
        }
        for note in map.notes where !excluded.contains(.note(note.id)) {
            if let at = note.at { rects.append(BoardGeometry.rect(ofNoteAt: at)) }
        }
        for text in map.texts where !excluded.contains(.text(text.id)) {
            rects.append(BoardGeometry.rect(of: text))
        }
        return rects
    }

    static func frameRects(_ map: BoardMap, excluding excluded: Set<String>) -> [BoardRect] {
        map.frames.filter { !excluded.contains($0.label) }.compactMap(\.rect)
    }

    static func index(of name: String, in map: BoardMap) -> Int? {
        map.components.firstIndex { $0.name.lowercased() == name.lowercased() }
    }

    static func uniqueName(_ base: String, taken: Set<String>, separator: String = "-") -> String {
        var name = base
        var suffix = 2
        while taken.contains(name.lowercased()) {
            name = "\(base)\(separator)\(suffix)"
            suffix += 1
        }
        return name
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
            let wanted = BoardRect(x: 0, y: 0,
                                   w: max(BoardGeometry.frameMinSize.x, columns * (size.x + gap) + gap),
                                   h: max(BoardGeometry.frameMinSize.y, rows * (size.y + gap) + gap)).snapped
            let content = elementRects(map, excluding: []) + frameRects(map, excluding: [])
            let seedX = (content.map(\.maxX).max() ?? 0) + (content.isEmpty ? 0 : 48)
            let rect = BoardGeometry.frameDrop(wanted.offsetBy(dx: seedX, dy: 0).snapped, otherFrames: [], foreignElements: content)
            map.frames.append(BoardFrame(label: localDocker, rect: rect))
        }

        var unplaced = false
        for suggestion in fresh {
            guard let frameIndex = map.frames.firstIndex(where: { $0.label == localDocker }), var frame = map.frames[frameIndex].rect else { break }
            // Everything already inside the frame is avoided — not just its components. A note
            // or text has no `place`, so membership is geometric: wholly inside the interior.
            let interior = BoardGeometry.interior(of: frame)
            let memberComponents = Set(map.components.filter { $0.place == localDocker }.map(\.name))
            let memberNotes = Set(map.notes.filter { $0.at.map { interior.contains(BoardGeometry.rect(ofNoteAt: $0)) } ?? false }.map(\.id))
            let memberTexts = Set(map.texts.filter { interior.contains(BoardGeometry.rect(of: $0)) }.map(\.id))
            let members = map.components.filter { memberComponents.contains($0.name) }.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
                + map.notes.filter { memberNotes.contains($0.id) }.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
                + map.texts.filter { memberTexts.contains($0.id) }.map(BoardGeometry.rect(of:))
            let excluded = Set(memberComponents.map { Element.component($0) })
                .union(memberNotes.map { Element.note($0) })
                .union(memberTexts.map { Element.text($0) })
            let foreign = elementRects(map, excluding: excluded).filter { !frame.contains($0) }
            let others = frameRects(map, excluding: [localDocker])
            let seed = BoardRect(x: frame.x + BoardGeometry.frameInset, y: frame.y + BoardGeometry.frameInset, w: size.x, h: size.y)
            var spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: members, inside: interior)
            if spot == nil, let grown = BoardGeometry.grow(frame, toFit: size, members: members, otherFrames: others, foreignElements: foreign) {
                frame = grown
                map.frames[frameIndex].rect = grown
                spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: members, inside: BoardGeometry.interior(of: grown))
            }
            let placed = spot ?? BoardGeometry.elementDrop(seed.offsetBy(dx: frame.w + 48, dy: 0),
                                                         otherElements: elementRects(map, excluding: []), frames: frameRects(map, excluding: []))
            let place = spot == nil ? BoardMap.notPlaced : localDocker
            if spot == nil { unplaced = true }
            map.components.append(BoardComponent(name: suggestion.name, kind: suggestion.kind, place: place, at: placed.origin))
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
            diskBytes = try store.save(map, expecting: diskBytes)
            hasUnwrittenEdits = false
            writeFailure = nil
        } catch BoardMapStoreError.changedOnDisk {
            changedOnDisk = true
        } catch {
            writeFailure = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? LinkCError { return error.localizedDescription }
        return String(describing: error)
    }
}
