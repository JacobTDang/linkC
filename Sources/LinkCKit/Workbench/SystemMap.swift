import Foundation

/// A tile's place on the board, in whole grid cells — so a drag produces a one-line diff.
public struct GridPoint: Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// What a component is. The known values drive the tile's glyph; any other value is kept
/// verbatim and drawn plainly, so a kind linkC has not learned yet never breaks a file.
public struct ComponentKind: Equatable, Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static let database = ComponentKind("database")
    public static let cache = ComponentKind("cache")
    public static let queue = ComponentKind("queue")
    public static let storage = ComponentKind("storage")
    public static let service = ComponentKind("service")
    public static let host = ComponentKind("host")
    public static let external = ComponentKind("external")

    public static let known: [ComponentKind] = [
        .database, .cache, .queue, .storage, .service, .host, .external,
    ]

    public var isKnown: Bool { Self.known.contains(self) }
}

/// One part of a project's system, as `.linkc/system.json` describes it.
public struct SystemComponent: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Identity. Unique within a file, and what discovery is matched against.
    public var name: String
    public var kind: ComponentKind
    /// How code reaches it: an env var name, a URL, a host.
    public var reachedBy: String?
    /// Where it lives — free text, but naming docker or compose is what makes it checkable.
    public var runs: String?
    /// What talks to it. Entries need not be components.
    public var usedBy: [String]
    /// True while it is only planned.
    public var intended: Bool
    /// Where its tile sits. nil means the board lays it out.
    public var at: GridPoint?
    /// The object this component was decoded from, so keys linkC does not know survive an edit.
    var extras: Data?

    public init(
        name: String, kind: ComponentKind, reachedBy: String? = nil, runs: String? = nil,
        usedBy: [String] = [], intended: Bool = false, at: GridPoint? = nil, extras: Data? = nil
    ) {
        self.name = name
        self.kind = kind
        self.reachedBy = reachedBy
        self.runs = runs
        self.usedBy = usedBy
        self.intended = intended
        self.at = at
        self.extras = extras
    }
}

/// A project's system map: the whole of `.linkc/system.json`.
public struct SystemMap: Equatable, Sendable {
    public var version: Int
    public var components: [SystemComponent]
    /// The object the file was decoded from, so top-level keys linkC does not know survive.
    var extras: Data?

    public init(version: Int = 1, components: [SystemComponent] = [], extras: Data? = nil) {
        self.version = version
        self.components = components
        self.extras = extras
    }

    public static let empty = SystemMap()

    /// Decodes a map, failing loud: an unreadable file must never read as an empty system.
    public static func decode(_ data: Data) throws -> SystemMap {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.parse("system.json is not JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw LinkCError.parse("system.json is not a JSON object")
        }
        guard let rawComponents = root["components"] as? [[String: Any]] else {
            throw LinkCError.parse("system.json has no components list")
        }

        var components: [SystemComponent] = []
        var seen: Set<String> = []
        for raw in rawComponents {
            guard let name = raw["name"] as? String, !name.isEmpty else {
                throw LinkCError.parse("a component in system.json has no name")
            }
            let key = name.lowercased()
            guard !seen.contains(key) else {
                throw LinkCError.parse("system.json names \"\(name)\" twice")
            }
            seen.insert(key)

            var at: GridPoint?
            if let point = raw["at"] as? [String: Any],
               let x = point["x"] as? Int, let y = point["y"] as? Int {
                at = GridPoint(x: x, y: y)
            }
            components.append(SystemComponent(
                name: name,
                kind: ComponentKind((raw["kind"] as? String) ?? ComponentKind.service.raw),
                reachedBy: raw["reached_by"] as? String,
                runs: raw["runs"] as? String,
                usedBy: (raw["used_by"] as? [String]) ?? [],
                intended: (raw["intended"] as? Bool) ?? false,
                at: at,
                extras: try? JSONSerialization.data(withJSONObject: raw)))
        }

        var rootExtras = root
        rootExtras.removeValue(forKey: "components")
        return SystemMap(
            version: (root["version"] as? Int) ?? 1,
            components: components,
            extras: try? JSONSerialization.data(withJSONObject: rootExtras))
    }

    /// The file's bytes, keeping every key linkC does not know and omitting empty fields.
    public func encoded() throws -> Data {
        var root = (extras.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        root["version"] = version
        root["components"] = components.map { component in
            var object = (component.extras.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]) ?? [:]
            object["name"] = component.name
            object["kind"] = component.kind.raw
            set(&object, "reached_by", component.reachedBy)
            set(&object, "runs", component.runs)
            if component.usedBy.isEmpty { object.removeValue(forKey: "used_by") } else { object["used_by"] = component.usedBy }
            if component.intended { object["intended"] = true } else { object.removeValue(forKey: "intended") }
            if let at = component.at { object["at"] = ["x": at.x, "y": at.y] } else { object.removeValue(forKey: "at") }
            return object
        }

        guard JSONSerialization.isValidJSONObject(root) else {
            throw LinkCError.parse("the system map could not be represented as JSON")
        }
        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw LinkCError.parse("failed to write the system map: \(error.localizedDescription)")
        }
    }

    /// Writes a value, or removes the key when it is nil or blank — an absent field is absent,
    /// never `null` and never `""`.
    private func set(_ object: inout [String: Any], _ key: String, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { object.removeValue(forKey: key) } else { object[key] = trimmed }
    }
}
