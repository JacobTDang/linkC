import Foundation

/// The editable fields of a component, as carried by an `add` or `update` step. `nil` means
/// "leave it alone" (for `update`) or "use the default" (for `add`); `""` clears `does`,
/// `reachedBy` or `runs`.
public struct BoardComponentFields: Equatable, Sendable {
    public var kind: ComponentKind?
    public var does: String?        // "" clears
    public var reachedBy: String?   // "" clears
    public var runs: String?        // "" clears
    public var planned: Bool?

    public init(kind: ComponentKind? = nil, does: String? = nil, reachedBy: String? = nil, runs: String? = nil, planned: Bool? = nil) {
        self.kind = kind
        self.does = does
        self.reachedBy = reachedBy
        self.runs = runs
        self.planned = planned
    }
}

/// One instruction from the `linkc_edit_board` tool.
public enum BoardEditStep: Equatable, Sendable {
    case add(String, BoardComponentFields, place: String?)
    case update(String, BoardComponentFields, place: String?, rename: String?)
    case remove(String)
    case connect(String, to: String, label: String?)
    case disconnect(String, to: String)
    case addPlace(String)
    case renamePlace(String, to: String)
    case removePlace(String)
    case note(String)
    case removeNote(String)
    case system(String)
}

/// A step `BoardEdit` would not apply, and why. `apply` is all-or-nothing: the first refusal
/// throws and nothing is returned. `step` is 1-based; `0` means the refusal is about the `steps`
/// list itself, not any one step in it, so `description` names no step number for it.
public struct BoardEditRefusal: Error, Equatable, CustomStringConvertible {
    public let step: Int          // 1-based; 0 for a refusal about the list itself
    public let reason: String
    public var description: String { step > 0 ? "step \(step): \(reason)" : reason }
}

/// Turns the MCP tool's `steps` argument into a `BoardMap`, by the Board's own placement and
/// naming rules. Pure and non-isolated: it calls `BoardModel`'s `nonisolated static` helpers
/// rather than reimplementing them, and never touches a live `BoardModel`.
public enum BoardEdit {
    public static let maxSteps = 50

    private static let verbKeys: Set<String> = [
        "add", "update", "remove", "connect", "disconnect", "place", "remove_place", "note", "remove_note", "system",
    ]
    private static let stringFieldKeys: Set<String> = ["kind", "does", "reached_by", "runs", "in", "rename", "to", "label"]
    private static let boolFieldKeys: Set<String> = ["planned"]

    /// The fields each verb accepts besides its own name-bearing key, in the order the tool's
    /// schema documents them — what an unknown-field refusal lists as "takes:".
    private static let allowedFields: [String: [String]] = [
        "add": ["kind", "in", "does", "reached_by", "runs", "planned"],
        "update": ["kind", "in", "does", "reached_by", "runs", "planned", "rename"],
        "remove": [],
        "connect": ["to", "label"],
        "disconnect": ["to"],
        "place": ["rename"],
        "remove_place": [],
        "note": [],
        "remove_note": [],
        "system": [],
    ]

    // MARK: - Decoding

    /// Decodes the tool's `steps` argument. Throws `BoardEditRefusal` for a malformed step.
    public static func steps(from json: Any?) throws -> [BoardEditStep] {
        guard let array = json as? [Any], !array.isEmpty, array.count <= maxSteps else {
            throw BoardEditRefusal(step: 0, reason: "steps must be a list of 1 to \(maxSteps) objects")
        }
        return try array.enumerated().map { index, raw in try decodeStep(raw, step: index + 1) }
    }

    private static func decodeStep(_ raw: Any, step: Int) throws -> BoardEditStep {
        guard let object = raw as? [String: Any] else {
            throw BoardEditRefusal(step: step, reason: "a step must be an object")
        }
        let verbsPresent = verbKeys.intersection(object.keys)
        guard verbsPresent.count == 1, let verb = verbsPresent.first else {
            throw BoardEditRefusal(step: step, reason: "needs exactly one of \(verbKeys.sorted().joined(separator: ", "))")
        }
        for key in object.keys where key != verb && !stringFieldKeys.contains(key) && !boolFieldKeys.contains(key) {
            let allowed = allowedFields[verb] ?? []
            let takes = allowed.isEmpty ? "(none)" : allowed.joined(separator: ", ")
            throw BoardEditRefusal(step: step, reason: "unknown field \"\(key)\" — \(verb) takes: \(takes)")
        }

        func stringField(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value as? String else { throw BoardEditRefusal(step: step, reason: "\"\(key)\" must be text") }
            return text
        }
        func boolField(_ key: String) throws -> Bool? {
            guard let value = object[key] else { return nil }
            // `JSONSerialization` bridges every number to `NSNumber`, and `NSNumber as? Bool`
            // bridges any of them — `1`, not just `true` — to `Bool`. A real boolean carries the
            // `CFBoolean` type; a plain number does not, so it is refused rather than silently
            // treated as true or false. Matches `BoardMapJSON.isBoolNumber`'s own check.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw BoardEditRefusal(step: step, reason: "\"\(key)\" must be true or false")
            }
            return number.boolValue
        }

        guard let verbValue = try stringField(verb) else {
            throw BoardEditRefusal(step: step, reason: "\"\(verb)\" must be text")
        }
        let kind = try stringField("kind")
        if kind == "" { throw BoardEditRefusal(step: step, reason: "\"kind\" must not be empty") }
        let does = try stringField("does")
        let reachedBy = try stringField("reached_by")
        let runs = try stringField("runs")
        let inPlace = try stringField("in")
        let rename = try stringField("rename")
        let to = try stringField("to")
        let label = try stringField("label")
        let planned = try boolField("planned")

        switch verb {
        case "add":
            let fields = BoardComponentFields(kind: kind.map(ComponentKind.init), does: does, reachedBy: reachedBy, runs: runs, planned: planned)
            return .add(verbValue, fields, place: inPlace)
        case "update":
            let fields = BoardComponentFields(kind: kind.map(ComponentKind.init), does: does, reachedBy: reachedBy, runs: runs, planned: planned)
            return .update(verbValue, fields, place: inPlace, rename: rename)
        case "remove":
            return .remove(verbValue)
        case "connect":
            guard let to else { throw BoardEditRefusal(step: step, reason: "\"connect\" needs \"to\"") }
            return .connect(verbValue, to: to, label: label)
        case "disconnect":
            guard let to else { throw BoardEditRefusal(step: step, reason: "\"disconnect\" needs \"to\"") }
            return .disconnect(verbValue, to: to)
        case "place":
            if let rename { return .renamePlace(verbValue, to: rename) }
            return .addPlace(verbValue)
        case "remove_place":
            return .removePlace(verbValue)
        case "note":
            return .note(verbValue)
        case "remove_note":
            return .removeNote(verbValue)
        case "system":
            return .system(verbValue)
        default:
            preconditionFailure("decodeStep: unhandled verb \"\(verb)\"")
        }
    }

    // MARK: - Applying

    /// Applies every step to a copy; the first refusal throws and nothing is returned.
    /// Returns the new map and one summary line per step.
    public static func apply(_ steps: [BoardEditStep], to map: BoardMap) throws -> (map: BoardMap, lines: [String]) {
        var map = BoardModel.laidOut(map)
        var lines: [String] = []
        for (index, step) in steps.enumerated() {
            lines.append(try applyStep(step, number: index + 1, to: &map))
        }
        return (map, lines)
    }

    private static func applyStep(_ step: BoardEditStep, number: Int, to map: inout BoardMap) throws -> String {
        switch step {
        case .add(let rawName, let fields, let place):
            return try applyAdd(rawName, fields, place: place, number: number, map: &map)
        case .update(let rawName, let fields, let place, let rename):
            return try applyUpdate(rawName, fields, place: place, rename: rename, number: number, map: &map)
        case .remove(let rawName):
            return try applyRemove(rawName, number: number, map: &map)
        case .connect(let rawSource, let to, let label):
            return try applyConnect(rawSource, to: to, label: label, number: number, map: &map)
        case .disconnect(let rawSource, let to):
            return try applyDisconnect(rawSource, to: to, number: number, map: &map)
        case .addPlace(let rawLabel):
            return try applyAddPlace(rawLabel, number: number, map: &map)
        case .renamePlace(let rawLabel, let to):
            return try applyRenamePlace(rawLabel, to: to, number: number, map: &map)
        case .removePlace(let rawLabel):
            return try applyRemovePlace(rawLabel, number: number, map: &map)
        case .note(let text):
            return applyNote(text, map: &map)
        case .removeNote(let text):
            return try applyRemoveNote(text, number: number, map: &map)
        case .system(let text):
            return applySystem(text, map: &map)
        }
    }

    // MARK: - add / update

    private static func applyAdd(_ rawName: String, _ fields: BoardComponentFields, place: String?, number: Int, map: inout BoardMap) throws -> String {
        let name = trimmed(rawName)
        guard !name.isEmpty else { throw BoardEditRefusal(step: number, reason: "A component needs a name.") }
        guard BoardModel.index(of: name, in: map) == nil else {
            throw BoardEditRefusal(step: number, reason: "a component named \"\(name)\" already exists")
        }
        let component = BoardComponent(
            name: name,
            kind: fields.kind ?? .service,
            does: fields.does,
            reachedBy: fields.reachedBy,
            runs: fields.runs,
            planned: fields.planned ?? false)
        try placeComponent(component, at: place, number: number, map: &map)
        let added = map.components.last!
        return "added \(added.name) (\(bracket(for: added)))" + (added.place != BoardMap.notPlaced ? " in \(added.place)" : "")
    }

    private static func applyUpdate(
        _ rawName: String, _ fields: BoardComponentFields, place: String?, rename: String?, number: Int, map: inout BoardMap
    ) throws -> String {
        let name = trimmed(rawName)
        let index = try requireComponent(name, in: map, step: number)
        let oldName = map.components[index].name
        var component = map.components[index]

        if let kind = fields.kind { component.kind = kind }
        if let does = fields.does { component.does = does.isEmpty ? nil : does }
        if let reachedBy = fields.reachedBy { component.reachedBy = reachedBy.isEmpty ? nil : reachedBy }
        if let runs = fields.runs { component.runs = runs.isEmpty ? nil : runs }
        if let planned = fields.planned { component.planned = planned }

        var newName: String?
        if let rename {
            let trimmedName = trimmed(rename)
            guard !trimmedName.isEmpty else { throw BoardEditRefusal(step: number, reason: "A component needs a name.") }
            if trimmedName.lowercased() != oldName.lowercased(), map.components.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
                throw BoardEditRefusal(step: number, reason: "This map already has a component named \"\(trimmedName)\".")
            }
            component.name = trimmedName
            newName = trimmedName
        }

        map.components[index] = component
        if let newName, newName != oldName {
            for other in map.components.indices {
                if let label = map.components[other].uses.removeValue(forKey: oldName) {
                    map.components[other].uses[newName] = label
                }
            }
        }

        if let place {
            let currentIndex = BoardModel.index(of: newName ?? oldName, in: map)!
            let moving = map.components.remove(at: currentIndex)
            try placeComponent(moving, at: place, number: number, map: &map)
        }

        if let newName, newName != oldName { return "renamed \(oldName) → \(newName)" }
        return "updated \(oldName)"
    }

    /// Places `component` per a step's `in` argument: `nil` drops it to the right of everything;
    /// `"Not placed"` (case-insensitively) does the same; any other name must be an existing
    /// frame. Always appends `component` to `map.components`.
    private static func placeComponent(_ component: BoardComponent, at place: String?, number: Int, map: inout BoardMap) throws {
        guard let place else {
            BoardModel.placeLoose(component, into: &map)
            return
        }
        let trimmedPlace = trimmed(place)
        guard trimmedPlace.lowercased() != BoardMap.notPlaced.lowercased() else {
            BoardModel.placeLoose(component, into: &map)
            return
        }
        let frameIndex = try requireFrame(trimmedPlace, in: map, step: number)
        let label = map.frames[frameIndex].label
        BoardModel.placeComponent(component, inFrame: label, into: &map)
    }

    private static func bracket(for component: BoardComponent) -> String {
        (component.planned ? "planned, " : "") + component.kind.raw
    }

    // MARK: - remove

    private static func applyRemove(_ rawName: String, number: Int, map: inout BoardMap) throws -> String {
        let name = trimmed(rawName)
        let index = try requireComponent(name, in: map, step: number)
        let removedName = map.components[index].name
        map.components.remove(at: index)
        for i in map.components.indices {
            // Case-insensitive, so a legacy-cased key from a hand-edited file is never left dangling.
            if let key = map.components[i].uses.keys.first(where: { $0.lowercased() == removedName.lowercased() }) {
                map.components[i].uses.removeValue(forKey: key)
            }
        }
        return "removed \(removedName)"
    }

    // MARK: - connect / disconnect

    private static func applyConnect(_ rawSource: String, to: String, label: String?, number: Int, map: inout BoardMap) throws -> String {
        let sourceName = trimmed(rawSource)
        let targetName = trimmed(to)
        let sourceIndex = try requireComponent(sourceName, in: map, step: number)
        let targetIndex = try requireComponent(targetName, in: map, step: number)
        let realSource = map.components[sourceIndex].name
        let realTarget = map.components[targetIndex].name
        guard realSource.lowercased() != realTarget.lowercased() else {
            throw BoardEditRefusal(step: number, reason: "An arrow needs two different components.")
        }
        // An existing arrow is found case-insensitively, as `BoardModel.addArrow` does, and
        // relabelled in place rather than duplicated — a legacy-cased key from a hand-edited file
        // is normalised to the component's real name.
        let existingKey = map.components[sourceIndex].uses.keys.first { $0.lowercased() == realTarget.lowercased() }
        let existing = existingKey.map { map.components[sourceIndex].uses[$0]! }
        let resolvedLabel = label.map(trimmed) ?? existing ?? ""
        if let existingKey, existingKey != realTarget {
            map.components[sourceIndex].uses.removeValue(forKey: existingKey)
        }
        map.components[sourceIndex].uses[realTarget] = resolvedLabel
        guard !resolvedLabel.isEmpty else { return "\(realSource) → \(realTarget)" }
        return "\(realSource) → \(realTarget) \"\(resolvedLabel)\""
    }

    private static func applyDisconnect(_ rawSource: String, to: String, number: Int, map: inout BoardMap) throws -> String {
        let sourceName = trimmed(rawSource)
        let targetName = trimmed(to)
        let sourceIndex = try requireComponent(sourceName, in: map, step: number)
        let realSource = map.components[sourceIndex].name
        guard let key = map.components[sourceIndex].uses.keys.first(where: { $0.lowercased() == targetName.lowercased() }) else {
            throw BoardEditRefusal(step: number, reason: "no arrow \(realSource) → \(targetName)")
        }
        map.components[sourceIndex].uses.removeValue(forKey: key)
        return "disconnected \(realSource) → \(key)"
    }

    // MARK: - places

    private static func applyAddPlace(_ rawLabel: String, number: Int, map: inout BoardMap) throws -> String {
        let label = try newFrameLabel(rawLabel, number: number, map: map)
        BoardModel.appendFrame(label: label, size: BoardGeometry.frameMinSize, into: &map)
        return "added place \(label)"
    }

    private static func applyRenamePlace(_ rawLabel: String, to: String, number: Int, map: inout BoardMap) throws -> String {
        let label = trimmed(rawLabel)
        let index = try requireFrame(label, in: map, step: number)
        let oldLabel = map.frames[index].label
        let newLabel = try newFrameLabel(to, number: number, map: map, exceptItself: oldLabel)
        map.frames[index].label = newLabel
        for i in map.components.indices where map.components[i].place == oldLabel {
            map.components[i].place = newLabel
        }
        return "renamed place \(oldLabel) → \(newLabel)"
    }

    private static func applyRemovePlace(_ rawLabel: String, number: Int, map: inout BoardMap) throws -> String {
        let label = trimmed(rawLabel)
        let index = try requireFrame(label, in: map, step: number)
        let realLabel = map.frames[index].label
        map.frames.remove(at: index)
        for i in map.components.indices where map.components[i].place == realLabel {
            map.components[i].place = BoardMap.notPlaced
        }
        return "removed place \(realLabel)"
    }

    /// Validates a place label being created (for `place` or a `rename`): trimmed, non-empty,
    /// not the reserved "Not placed", and not already used by a different frame. Matches
    /// `BoardModel.renameFrame`'s own checks.
    private static func newFrameLabel(_ raw: String, number: Int, map: BoardMap, exceptItself current: String? = nil) throws -> String {
        let label = trimmed(raw)
        guard !label.isEmpty else { throw BoardEditRefusal(step: number, reason: "A frame needs a label.") }
        guard label.lowercased() != BoardMap.notPlaced.lowercased() else {
            throw BoardEditRefusal(step: number, reason: "\"\(BoardMap.notPlaced)\" is reserved for things outside every frame.")
        }
        if label.lowercased() != (current?.lowercased() ?? ""), map.frames.contains(where: { $0.label.lowercased() == label.lowercased() }) {
            throw BoardEditRefusal(step: number, reason: "This map already has a frame labelled \"\(label)\".")
        }
        return label
    }

    // MARK: - notes / system

    /// A new note, positioned to the right of everything on the board — the same drop rule
    /// `BoardModel.placeLoose` follows for a component, sized for a note.
    private static func applyNote(_ text: String, map: inout BoardMap) -> String {
        let content = BoardModel.elementRects(map, excluding: []) + BoardModel.frameRects(map, excluding: [])
        let seed = BoardGeometry.rect(ofNoteAt: BoardPoint(x: (content.map(\.maxX).max() ?? 0) + 48, y: 0))
        let landed = BoardGeometry.elementDrop(seed, otherElements: BoardModel.elementRects(map, excluding: []), frames: BoardModel.frameRects(map, excluding: []))
        map.notes.append(BoardNote(text: text, at: landed.origin))
        return "added a note"
    }

    private static func applyRemoveNote(_ text: String, number: Int, map: inout BoardMap) throws -> String {
        guard let index = map.notes.firstIndex(where: { $0.text == text }) else {
            throw BoardEditRefusal(step: number, reason: "no note \"\(text)\"")
        }
        map.notes.remove(at: index)
        return "removed a note"
    }

    private static func applySystem(_ text: String, map: inout BoardMap) -> String {
        let trimmedText = trimmed(text)
        map.system = trimmedText.isEmpty ? nil : trimmedText
        return "set the summary"
    }

    // MARK: - Lookups shared by every step

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func componentsList(_ map: BoardMap) -> String {
        let names = map.components.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
        return names.isEmpty ? "(none)" : names.joined(separator: ", ")
    }

    private static func placesList(_ map: BoardMap) -> String {
        let labels = map.frames.map(\.label).sorted { $0.lowercased() < $1.lowercased() }
        return labels.isEmpty ? "(none)" : labels.joined(separator: ", ")
    }

    private static func requireComponent(_ name: String, in map: BoardMap, step: Int) throws -> Int {
        guard let index = BoardModel.index(of: name, in: map) else {
            throw BoardEditRefusal(step: step, reason: "no component \"\(name)\" — components: \(componentsList(map))")
        }
        return index
    }

    private static func requireFrame(_ label: String, in map: BoardMap, step: Int) throws -> Int {
        guard let index = map.frames.firstIndex(where: { $0.label.lowercased() == label.lowercased() }) else {
            throw BoardEditRefusal(step: step, reason: "no place \"\(label)\" — places: \(placesList(map))")
        }
        return index
    }
}
