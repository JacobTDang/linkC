import Foundation

/// A point on the board, in canvas points. Stored snapped to 8, so moving a box changes one line.
public struct BoardPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// The step every stored coordinate lands on.
    public static let grid = 8

    public var snapped: BoardPoint { BoardPoint(x: Self.snap(x), y: Self.snap(y)) }

    static func snap(_ value: Int) -> Int {
        Int((Double(value) / Double(grid)).rounded()) * grid
    }
}

/// A rectangle on the board. Edges that only touch do not overlap.
public struct BoardRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
    public var origin: BoardPoint { BoardPoint(x: x, y: y) }
    public var center: BoardPoint { BoardPoint(x: x + w / 2, y: y + h / 2) }

    public func intersects(_ other: BoardRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func contains(_ point: BoardPoint) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    public func contains(_ rect: BoardRect) -> Bool {
        rect.x >= x && rect.y >= y && rect.maxX <= maxX && rect.maxY <= maxY
    }

    public func offsetBy(dx: Int, dy: Int) -> BoardRect {
        BoardRect(x: x + dx, y: y + dy, w: w, h: h)
    }

    /// Origin and size on the 8-point grid; a size never snaps below one step.
    public var snapped: BoardRect {
        BoardRect(
            x: BoardPoint.snap(x), y: BoardPoint.snap(y),
            w: max(BoardPoint.grid, BoardPoint.snap(w)), h: max(BoardPoint.grid, BoardPoint.snap(h)))
    }
}

/// How an arrow is drawn. `.plain` is what the file has always had.
public enum BoardArrowStyle: String, Sendable, CaseIterable {
    case plain, conditional, control, bus

    /// The style a new arrow takes when nothing says otherwise: conditional from a router,
    /// control from a control unit, plain from anything else.
    public static func `default`(from source: ComponentKind) -> BoardArrowStyle {
        switch source {
        case .router: return .conditional
        case .control: return .control
        default: return .plain
        }
    }
}

/// One `uses` edge: its label, and how it should be drawn. `bits` only means anything with
/// `.bus`. `ExpressibleByStringLiteral` keeps `uses: ["b": "x"]` reading naturally, in code and
/// in tests — a plain arrow is just its label.
public struct BoardArrow: Equatable, Sendable, ExpressibleByStringLiteral {
    public var label: String
    public var style: BoardArrowStyle
    public var bits: Int?

    public init(label: String = "", style: BoardArrowStyle = .plain, bits: Int? = nil) {
        self.label = label
        self.style = style
        self.bits = bits
    }

    public init(stringLiteral value: String) {
        self.init(label: value)
    }
}

/// One part of the system: a box on the board, and an entry under its place in the file.
public struct BoardComponent: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Identity: unique across the whole file, and what running things are matched against.
    public var name: String
    public var kind: ComponentKind
    /// One line saying what it is for.
    public var does: String?
    /// How code reaches it: an env var name, a URL, a host.
    public var reachedBy: String?
    /// Where it runs, free text; naming a compose service in brackets is what matches it.
    public var runs: String?
    /// The technology it is, e.g. "postgres", "redis", "docker" — drives which logo is drawn.
    public var tech: String?
    /// True while it does not exist yet.
    public var planned: Bool
    /// What it uses: each component's name, mapped to the arrow to it.
    public var uses: [String: BoardArrow]
    /// Version-1 `used_by` names that were not components, kept verbatim.
    public var legacyUsedBy: [String]
    /// The label of the frame it sits in, or `BoardMap.notPlaced`.
    public var place: String
    /// Its box's top-left corner; nil until the board places it.
    public var at: BoardPoint?
    public var columns: [BoardColumn]
    /// Keys linkC does not know, kept so an edit never drops them.
    var extras: Data?

    public init(
        name: String, kind: ComponentKind, does: String? = nil, reachedBy: String? = nil, runs: String? = nil,
        tech: String? = nil, planned: Bool = false, uses: [String: BoardArrow] = [:], legacyUsedBy: [String] = [],
        place: String = BoardMap.notPlaced, at: BoardPoint? = nil, columns: [BoardColumn] = []
    ) {
        self.name = name
        self.kind = kind
        self.does = does
        self.reachedBy = reachedBy
        self.runs = runs
        self.tech = tech
        self.planned = planned
        self.uses = uses
        self.legacyUsedBy = legacyUsedBy
        self.place = place
        self.at = at
        self.columns = columns
        self.extras = nil
    }
}

/// A labelled region; its label is a place in the file.
public struct BoardFrame: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    /// nil until the board lays it out — a place written by hand has no geometry yet.
    public var rect: BoardRect?

    public init(label: String, rect: BoardRect? = nil) {
        self.label = label
        self.rect = rect
    }
}

public enum BoardTextStyle: String, Sendable {
    case title
    case label
}

/// A sticky note. Its id lives only in memory; the file keeps notes in order.
public struct BoardNote: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var at: BoardPoint?

    public init(id: UUID = UUID(), text: String, at: BoardPoint? = nil) {
        self.id = id
        self.text = text
        self.at = at
    }
}

/// A heading or label on the canvas. Visual only: agents never read it.
public struct BoardText: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var style: BoardTextStyle
    public var at: BoardPoint
    /// The width the board measured for it, so collisions never depend on laying out text.
    public var width: Int
    /// Keys linkC does not know, kept so an edit never drops them.
    var extras: Data?

    public init(id: UUID = UUID(), text: String, style: BoardTextStyle, at: BoardPoint, width: Int) {
        self.id = id
        self.text = text
        self.style = style
        self.at = at
        self.width = width
        self.extras = nil
    }
}

/// The whole of `system-map.json`, version 2: the architecture first, the board's layout last.
public struct BoardMap: Equatable, Sendable {
    /// The reserved place for components outside every frame. Always written.
    public static let notPlaced = "Not placed"

    public var system: String?
    public var components: [BoardComponent] = []
    public var frames: [BoardFrame] = []
    public var notes: [BoardNote] = []
    public var texts: [BoardText] = []
    /// Top-level keys linkC does not know.
    var extras: Data?
    /// Keys inside `layout` linkC does not know.
    var layoutExtras: Data?

    public init(system: String? = nil) {
        self.system = system
    }

    public static let empty = BoardMap()

    private static let rootKeys: Set<String> = ["version", "system", "places", "notes", "layout"]
    private static let componentKeys: Set<String> = ["kind", "does", "reached_by", "runs", "tech", "status", "uses", "used_by", "columns"]
    private static let layoutKeys: Set<String> = ["components", "frames", "notes", "texts"]
    private static let textKeys: Set<String> = ["text", "style", "at", "w"]
    /// Every version-1 component key linkC now knows, version-2 fields included: a version-1
    /// component that also carries `does`, `status` or `uses` must read them typed, not verbatim.
    private static let versionOneComponentKeys: Set<String> = [
        "name", "kind", "does", "reached_by", "runs", "tech", "status", "uses", "used_by", "intended", "at", "columns",
    ]
    /// Every version-1 root key linkC now knows, version-2 fields included: `system` and `notes`
    /// on a version-1 file read typed, not verbatim.
    private static let versionOneRootKeys: Set<String> = ["version", "components", "system", "notes"]

    // MARK: - Decoding

    /// Decodes versions 1 and 2, failing loud: an unreadable file must never read as an empty system.
    public static func decode(_ data: Data) throws -> BoardMap {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.parse("system-map.json is not JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw LinkCError.parse("system-map.json is not a JSON object")
        }
        let version = try int(root, "version", context: "system-map.json")
        if let version, version > 2 {
            throw LinkCError.parse("system-map.json is version \(version), written by a newer linkC")
        }
        if root["places"] != nil || version == 2 { return try decodeVersionTwo(root) }
        if root["components"] != nil { return try decodeVersionOne(root) }
        throw LinkCError.parse("system-map.json has neither places nor components")
    }

    private static func decodeVersionTwo(_ root: [String: Any]) throws -> BoardMap {
        guard let rawPlaces = root["places"] as? [String: Any] else {
            throw LinkCError.parse("system-map.json has no places")
        }
        let layoutContext = "the layout in system-map.json"
        let layout = try dictionary(root, "layout", context: "system-map.json") ?? [:]
        // An entry here naming something absent from `places` has nothing to attach to below —
        // it is deliberately dropped: a position for a component or frame that does not exist
        // is meaningless, and it never resurfaces on the next encode.
        let positions = try pointMap(layout, "components", context: layoutContext) ?? [:]
        let frameRects = try rectMap(layout, "frames", context: layoutContext) ?? [:]

        var map = BoardMap(system: try string(root, "system", context: "system-map.json"))
        var seenPlaces: Set<String> = []
        var seenNames: Set<String> = []
        for placeName in rawPlaces.keys.sorted() {
            guard !placeName.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LinkCError.parse("a place in system-map.json has no name")
            }
            guard seenPlaces.insert(placeName.lowercased()).inserted else {
                throw LinkCError.parse("system-map.json names the place \"\(placeName)\" twice")
            }
            guard let members = rawPlaces[placeName] as? [String: Any] else {
                throw LinkCError.parse("the place \"\(placeName)\" in system-map.json is not an object of components")
            }
            let isUnplaced = placeName.lowercased() == notPlaced.lowercased()
            let place = isUnplaced ? notPlaced : placeName
            if !isUnplaced { map.frames.append(BoardFrame(label: placeName, rect: frameRects[placeName])) }

            for name in members.keys.sorted() {
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw LinkCError.parse("a component under \"\(placeName)\" in system-map.json has no name")
                }
                guard seenNames.insert(name.lowercased()).inserted else {
                    throw LinkCError.parse("system-map.json names \"\(name)\" twice")
                }
                guard let raw = members[name] as? [String: Any] else {
                    throw LinkCError.parse("component \"\(name)\" in system-map.json is not an object")
                }
                let context = "component \"\(name)\" in system-map.json"
                var component = BoardComponent(
                    name: name,
                    kind: ComponentKind(try string(raw, "kind", context: context) ?? ComponentKind.service.raw),
                    does: try string(raw, "does", context: context),
                    reachedBy: try string(raw, "reached_by", context: context),
                    runs: try string(raw, "runs", context: context),
                    tech: try string(raw, "tech", context: context),
                    planned: try plannedStatus(raw, context: context),
                    uses: try arrowMap(raw, "uses", context: context) ?? [:],
                    legacyUsedBy: try stringArray(raw, "used_by", context: context) ?? [],
                    place: place,
                    at: positions[name],
                    columns: try columns(raw, context: context))
                component.extras = try extras(of: raw, excluding: componentKeys, context: context)
                map.components.append(component)
            }
        }

        let noteTexts = try stringArray(root, "notes", context: "system-map.json") ?? []
        // Deliberately dropped, same as above: a `layout.notes` entry past the end of `notes`
        // has no note left to place, so the zip below never reaches it.
        let notePositions = try optionalPointList(layout, "notes", context: layoutContext) ?? []
        map.notes = noteTexts.enumerated().map { index, text in
            BoardNote(text: text, at: index < notePositions.count ? notePositions[index] : nil)
        }
        map.texts = try texts(layout, context: layoutContext)
        map.extras = try extras(of: root, excluding: rootKeys, context: "system-map.json")
        map.layoutExtras = try extras(of: layout, excluding: layoutKeys, context: layoutContext)
        return map
    }

    private static func decodeVersionOne(_ root: [String: Any]) throws -> BoardMap {
        // A layout cannot be meaningfully merged into a version-1 list: refuse rather than guess.
        guard root["layout"] == nil else {
            throw LinkCError.parse(
                "system-map.json mixes version 1 and version 2: it has \"layout\", which only version 2 supports; "
                    + "set \"version\": 2 to use it, or remove \"layout\" to stay on version 1")
        }
        guard let rawComponents = root["components"] as? [[String: Any]] else {
            throw LinkCError.parse("system-map.json has no components list")
        }
        var components: [BoardComponent] = []
        var usedBy: [[String]] = []
        var seen: Set<String> = []
        for raw in rawComponents {
            guard let name = raw["name"] as? String, !name.isEmpty else {
                throw LinkCError.parse("a component in system-map.json has no name")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw LinkCError.parse("system-map.json names \"\(name)\" twice")
            }
            let context = "component \"\(name)\" in system-map.json"
            var at: BoardPoint?
            if let value = raw["at"] {
                guard let cell = value as? [String: Any], let x = cell["x"] as? Int, let y = cell["y"] as? Int else {
                    throw LinkCError.parse("\(context) has \"at\" but it needs whole-number x and y")
                }
                at = BoardPoint(x: x * 160, y: y * 64)
            }
            // "intended" is version 1's own flag; "status" is version 2's. Either check must run
            // regardless of the other, so a bad status is never skipped just because intended is set.
            let intended = try bool(raw, "intended", context: context) ?? false
            let statusPlanned = try plannedStatus(raw, context: context)
            var component = BoardComponent(
                name: name,
                kind: ComponentKind(try string(raw, "kind", context: context) ?? ComponentKind.service.raw),
                does: try string(raw, "does", context: context),
                reachedBy: try string(raw, "reached_by", context: context),
                runs: try string(raw, "runs", context: context),
                tech: try string(raw, "tech", context: context),
                planned: intended || statusPlanned,
                uses: try arrowMap(raw, "uses", context: context) ?? [:],
                at: at)
            component.extras = try extras(of: raw, excluding: versionOneComponentKeys, context: context)
            components.append(component)
            usedBy.append(try stringArray(raw, "used_by", context: context) ?? [])
        }

        // Version 1 said who uses a component; version 2 says what a component uses. A
        // component's own explicit "uses" always wins — used_by only fills in a key not already there.
        let indexByName = Dictionary(uniqueKeysWithValues: components.enumerated().map { ($0.element.name.lowercased(), $0.offset) })
        for (index, users) in usedBy.enumerated() {
            for user in users {
                if let userIndex = indexByName[user.lowercased()] {
                    let usedName = components[index].name
                    if components[userIndex].uses[usedName] == nil {
                        components[userIndex].uses[usedName] = ""
                    }
                } else {
                    components[index].legacyUsedBy.append(user)
                }
            }
        }

        var map = BoardMap(system: try string(root, "system", context: "system-map.json"))
        map.components = components
        map.notes = (try stringArray(root, "notes", context: "system-map.json") ?? []).map { BoardNote(text: $0) }
        map.extras = try extras(of: root, excluding: versionOneRootKeys, context: "system-map.json")
        return map
    }

    // MARK: - Encoding

    /// The file's bytes: version 2, architecture first, layout last, sorted and snapped.
    public func encoded() throws -> Data {
        try Self.writtenJSON(rootObject())
    }

    /// The architecture an agent is shown: `encoded()`'s own root, minus `layout` — no
    /// coordinates, since they mean nothing to an agent. Same key order `BoardMapJSON` gives the
    /// file itself, since this is that same root with one key removed.
    public func architectureJSON() throws -> String {
        var root = try rootObject()
        root.removeValue(forKey: "layout")
        guard let text = String(data: try Self.writtenJSON(root), encoding: .utf8) else {
            throw LinkCError.parse("the system map's architecture could not be represented as text")
        }
        return text
    }

    /// Everything `encoded()` writes — architecture and layout both — as the untyped JSON object
    /// `BoardMapJSON` orders and renders. Shared so `architectureJSON()` never re-derives the
    /// architecture by any rule of its own.
    private func rootObject() throws -> [String: Any] {
        var root = try Self.object(from: extras, context: "the system map's own extras")
        root["version"] = 2
        Self.set(&root, "system", system)

        var places: [String: [String: Any]] = [Self.notPlaced: [:]]
        for frame in frames { places[frame.label] = places[frame.label] ?? [:] }
        for component in components {
            var object = try Self.object(from: component.extras, context: "component \"\(component.name)\"'s extras")
            object["kind"] = component.kind.raw
            Self.set(&object, "does", component.does)
            Self.set(&object, "reached_by", component.reachedBy)
            Self.set(&object, "runs", component.runs)
            Self.set(&object, "tech", component.tech)
            if component.planned { object["status"] = "planned" } else { object.removeValue(forKey: "status") }
            if component.uses.isEmpty { object.removeValue(forKey: "uses") } else { object["uses"] = Self.encodedUses(component.uses) }
            if component.legacyUsedBy.isEmpty { object.removeValue(forKey: "used_by") } else { object["used_by"] = component.legacyUsedBy }
            if component.columns.isEmpty {
                object.removeValue(forKey: "columns")
            } else {
                object["columns"] = component.columns.map(Self.encodedColumn)
            }
            places[component.place, default: [:]][component.name] = object
        }
        root["places"] = places
        root["notes"] = notes.map(\.text)

        var layout = try Self.object(from: layoutExtras, context: "the layout's extras")
        var positions: [String: [Int]] = [:]
        for component in components {
            if let at = component.at?.snapped { positions[component.name] = [at.x, at.y] }
        }
        var rects: [String: [Int]] = [:]
        for frame in frames {
            if let rect = frame.rect?.snapped { rects[frame.label] = [rect.x, rect.y, rect.w, rect.h] }
        }
        layout["components"] = positions
        layout["frames"] = rects
        layout["notes"] = notes.map { note -> Any in
            guard let at = note.at?.snapped else { return NSNull() }
            return [at.x, at.y]
        }
        layout["texts"] = try texts.map { text -> [String: Any] in
            var object = try Self.object(from: text.extras, context: "text \"\(text.text)\"'s extras")
            let at = text.at.snapped
            object["text"] = text.text
            object["style"] = text.style.rawValue
            object["at"] = [at.x, at.y]
            object["w"] = text.width
            return object
        }
        root["layout"] = layout
        return root
    }

    private static func writtenJSON(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw LinkCError.parse("the system map could not be represented as JSON")
        }
        return try BoardMapJSON.write(root)
    }

    // MARK: - Field readers: a known key present with the wrong type refuses the whole file

    private static func string(_ raw: [String: Any], _ key: String, context: String) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let string = value as? String else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not text") }
        return string
    }

    /// Reads "status", whose only allowed value is "planned" — the same check both versions apply.
    private static func plannedStatus(_ raw: [String: Any], context: String) throws -> Bool {
        guard let status = try string(raw, "status", context: context) else { return false }
        guard status == "planned" else {
            throw LinkCError.parse("\(context) has status \"\(status)\"; the only status is \"planned\"")
        }
        return true
    }

    private static func bool(_ raw: [String: Any], _ key: String, context: String) throws -> Bool? {
        guard let value = raw[key] else { return nil }
        guard let bool = value as? Bool else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not true or false") }
        return bool
    }

    private static func int(_ raw: [String: Any], _ key: String, context: String) throws -> Int? {
        guard let value = raw[key] else { return nil }
        // A `CFBoolean`-typed `NSNumber` bridges to `Int` just as readily as a real one — `true`
        // reads as `1` — so it is refused rather than silently accepted. Matches `BoardEdit`'s
        // own check on the same field.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not a whole number")
        }
        guard let int = value as? Int else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not a whole number") }
        return int
    }

    private static func stringArray(_ raw: [String: Any], _ key: String, context: String) throws -> [String]? {
        guard let value = raw[key] else { return nil }
        guard let array = value as? [String] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not a list of text") }
        return array
    }

    private static func columns(_ raw: [String: Any], context: String) throws -> [BoardColumn] {
        guard let value = raw["columns"] else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw LinkCError.parse("\(context) has \"columns\" but it is not a list of objects")
        }
        let knownKeys: Set<String> = ["name", "type", "pk", "nullable", "unique", "default", "references", "status"]
        var result: [BoardColumn] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let name = try string(entry, "name", context: context),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LinkCError.parse("\(context) has a column with no \"name\"")
            }
            let columnContext = "\(context)'s column \"\(name)\""
            if let unknown = entry.keys.sorted().first(where: { !knownKeys.contains($0) }) {
                throw LinkCError.parse("\(context) column \"\(name)\" has an unknown key \"\(unknown)\"")
            }
            guard let type = try string(entry, "type", context: columnContext),
                  !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LinkCError.parse("\(context) column \"\(name)\" has no \"type\"")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw LinkCError.parse("\(context) names column \"\(name)\" twice")
            }
            let pk = try bool(entry, "pk", context: columnContext) ?? false
            let nullable = try bool(entry, "nullable", context: columnContext) ?? true
            if pk && entry["nullable"] != nil && nullable {
                throw LinkCError.parse("\(context) column \"\(name)\" is a primary key, so it can't be nullable")
            }
            var reference: BoardColumnReference?
            if let referenceText = try string(entry, "references", context: columnContext) {
                guard let parsed = BoardColumnReference(parsing: referenceText) else {
                    throw LinkCError.parse("\(context) column \"\(name)\" has \"references\" \"\(referenceText)\" but it is not table.column")
                }
                reference = parsed
            }
            result.append(BoardColumn(
                name: name,
                type: type,
                pk: pk,
                nullable: nullable,
                unique: try bool(entry, "unique", context: columnContext) ?? false,
                defaultValue: try string(entry, "default", context: columnContext),
                references: reference,
                planned: try plannedStatus(entry, context: columnContext)))
        }
        return result
    }

    private static func encodedColumn(_ column: BoardColumn) -> [String: Any] {
        var object: [String: Any] = ["name": column.name, "type": column.type]
        if column.pk { object["pk"] = true }
        if !column.nullable && !column.pk { object["nullable"] = false }
        if column.unique { object["unique"] = true }
        if let defaultValue = column.defaultValue { object["default"] = defaultValue }
        if let references = column.references { object["references"] = references.text }
        if column.planned { object["status"] = "planned" }
        return object
    }

    private static func arrowMap(_ raw: [String: Any], _ key: String, context: String) throws -> [String: BoardArrow]? {
        guard let value = raw[key] else { return nil }
        guard let object = value as? [String: Any] else {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object")
        }
        var result: [String: BoardArrow] = [:]
        for (target, entry) in object {
            result[target] = try arrow(entry, in: context, to: target)
        }
        return result
    }

    /// One `uses` value: a string is a plain arrow with that label; an object may carry
    /// `label`, `style` and `bits`. Refused loud, naming both the component (from `context`) and
    /// the target, on an unknown key, a wrong type, an unknown style, `bits` without
    /// `style: "bus"`, or `bits` outside 1…4096.
    private static func arrow(_ entry: Any, in context: String, to target: String) throws -> BoardArrow {
        if let label = entry as? String { return BoardArrow(label: label) }
        let arrowContext = "\(context)'s arrow to \"\(target)\""
        guard let object = entry as? [String: Any] else {
            throw LinkCError.parse("\(arrowContext) is not text or an object")
        }
        let knownKeys: Set<String> = ["label", "style", "bits"]
        if let unknownKey = object.keys.sorted().first(where: { !knownKeys.contains($0) }) {
            throw LinkCError.parse("\(arrowContext) has an unknown key \"\(unknownKey)\"")
        }
        let label = try string(object, "label", context: arrowContext) ?? ""
        let styleName = try string(object, "style", context: arrowContext) ?? BoardArrowStyle.plain.rawValue
        guard let style = BoardArrowStyle(rawValue: styleName) else {
            throw LinkCError.parse("\(arrowContext) has style \"\(styleName)\"; styles are plain, conditional, control and bus")
        }
        let bits = try int(object, "bits", context: arrowContext)
        if let bits {
            guard style == .bus else {
                throw LinkCError.parse("\(arrowContext) has \"bits\" but its style is not \"bus\"")
            }
            guard (1...4096).contains(bits) else {
                throw LinkCError.parse("\(arrowContext) has \"bits\" \(bits) but it must be between 1 and 4096")
            }
        }
        return BoardArrow(label: label, style: style, bits: bits)
    }

    /// `uses`, ready to write: a `.plain` arrow is its label string; any other style is an
    /// object. Key order is left to `BoardMapJSON`, which sorts every object's keys already.
    private static func encodedUses(_ uses: [String: BoardArrow]) -> [String: Any] {
        uses.mapValues(encodedArrow)
    }

    private static func encodedArrow(_ arrow: BoardArrow) -> Any {
        guard arrow.style != .plain else { return arrow.label }
        var object: [String: Any] = ["style": arrow.style.rawValue]
        if !arrow.label.isEmpty { object["label"] = arrow.label }
        if arrow.style == .bus, let bits = arrow.bits { object["bits"] = bits }
        return object
    }

    private static func dictionary(_ raw: [String: Any], _ key: String, context: String) throws -> [String: Any]? {
        guard let value = raw[key] else { return nil }
        guard let object = value as? [String: Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object") }
        return object
    }

    private static func point(_ value: Any) -> BoardPoint? {
        guard let pair = value as? [Int], pair.count == 2 else { return nil }
        return BoardPoint(x: pair[0], y: pair[1])
    }

    private static func pointMap(_ raw: [String: Any], _ key: String, context: String) throws -> [String: BoardPoint]? {
        guard let value = raw[key] else { return nil }
        guard let entries = value as? [String: Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object") }
        var result: [String: BoardPoint] = [:]
        for (name, entry) in entries {
            guard let point = point(entry) else {
                throw LinkCError.parse("\(context) has \"\(key)\" → \"\(name)\" but it is not [x, y]")
            }
            result[name] = point
        }
        return result
    }

    private static func rectMap(_ raw: [String: Any], _ key: String, context: String) throws -> [String: BoardRect]? {
        guard let value = raw[key] else { return nil }
        guard let entries = value as? [String: Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object") }
        var result: [String: BoardRect] = [:]
        for (label, entry) in entries {
            guard let four = entry as? [Int], four.count == 4, four[2] > 0, four[3] > 0 else {
                throw LinkCError.parse("\(context) has \"\(key)\" → \"\(label)\" but it is not [x, y, w, h]")
            }
            result[label] = BoardRect(x: four[0], y: four[1], w: four[2], h: four[3])
        }
        return result
    }

    private static func optionalPointList(_ raw: [String: Any], _ key: String, context: String) throws -> [BoardPoint?]? {
        guard let value = raw[key] else { return nil }
        guard let entries = value as? [Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not a list") }
        return try entries.enumerated().map { index, entry in
            if entry is NSNull { return nil }
            guard let point = point(entry) else {
                throw LinkCError.parse("\(context) has \"\(key)\" item \(index + 1) but it is not [x, y] or null")
            }
            return point
        }
    }

    private static func texts(_ layout: [String: Any], context: String) throws -> [BoardText] {
        guard let value = layout["texts"] else { return [] }
        guard let entries = value as? [[String: Any]] else { throw LinkCError.parse("\(context) has \"texts\" but it is not a list of objects") }
        return try entries.enumerated().map { index, entry in
            let itemContext = "\(context), text \(index + 1)"
            guard let text = entry["text"] as? String else { throw LinkCError.parse("\(itemContext) has no text") }
            guard let at = entry["at"].flatMap(point) else { throw LinkCError.parse("\(itemContext) has no [x, y] at") }
            let styleName = try string(entry, "style", context: itemContext) ?? BoardTextStyle.label.rawValue
            guard let style = BoardTextStyle(rawValue: styleName) else {
                throw LinkCError.parse("\(itemContext) has style \"\(styleName)\"; styles are title and label")
            }
            let width = try int(entry, "w", context: itemContext) ?? 0
            var boardText = BoardText(text: text, style: style, at: at, width: width)
            boardText.extras = try extras(of: entry, excluding: textKeys, context: itemContext)
            return boardText
        }
    }

    /// The keys of `raw` outside `known`, recorded verbatim; nil when there are none.
    private static func extras(of raw: [String: Any], excluding known: Set<String>, context: String) throws -> Data? {
        let unknown = raw.filter { !known.contains($0.key) }
        guard !unknown.isEmpty else { return nil }
        do {
            return try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        } catch {
            throw LinkCError.parse("\(context) could not be recorded verbatim: \(error.localizedDescription)")
        }
    }

    /// Reads a recorded `extras` blob back. Unknown keys surviving an edit is a guarantee, so a
    /// blob that will not read back fails the write rather than quietly dropping them.
    private static func object(from data: Data?, context: String) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LinkCError.parse("\(context) did not decode back into an object")
            }
            return object
        } catch let error as LinkCError {
            throw error
        } catch {
            throw LinkCError.parse("\(context) could not be read back: \(error.localizedDescription)")
        }
    }

    /// Writes trimmed text, or removes the key when it is nil or blank — never `null`, never `""`.
    private static func set(_ object: inout [String: Any], _ key: String, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { object.removeValue(forKey: key) } else { object[key] = trimmed }
    }
}
