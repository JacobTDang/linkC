import Foundation

/// A tile's place on the board, in whole grid cells — so a drag produces a one-line diff.
public struct GridPoint: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// One part of a project's system, as `system-map.json` describes it.
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
    /// Left out of the public initialiser on purpose — only `SystemMap.decode` carries it, by
    /// assigning this internal var directly, so code outside the module can never set it.
    var extras: Data?

    public init(
        name: String, kind: ComponentKind, reachedBy: String? = nil, runs: String? = nil,
        usedBy: [String] = [], intended: Bool = false, at: GridPoint? = nil
    ) {
        self.name = name
        self.kind = kind
        self.reachedBy = reachedBy
        self.runs = runs
        self.usedBy = usedBy
        self.intended = intended
        self.at = at
        self.extras = nil
    }
}

/// A project's system map: the whole of `system-map.json`.
public struct SystemMap: Equatable, Sendable {
    public var version: Int
    public var components: [SystemComponent]
    /// The object the file was decoded from, so top-level keys linkC does not know survive.
    /// Left out of the public initialiser on purpose — only `SystemMap.decode` carries it, by
    /// assigning this internal var directly, so code outside the module can never set it.
    var extras: Data?

    public init(version: Int = 1, components: [SystemComponent] = []) {
        self.version = version
        self.components = components
        self.extras = nil
    }

    public static let empty = SystemMap()

    /// Decodes a map, failing loud: an unreadable file must never read as an empty system.
    public static func decode(_ data: Data) throws -> SystemMap {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.parse("system-map.json is not JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw LinkCError.parse("system-map.json is not a JSON object")
        }
        guard let rawComponents = root["components"] as? [[String: Any]] else {
            throw LinkCError.parse("system-map.json has no components list")
        }

        var components: [SystemComponent] = []
        var seen: Set<String> = []
        for raw in rawComponents {
            guard let name = raw["name"] as? String, !name.isEmpty else {
                throw LinkCError.parse("a component in system-map.json has no name")
            }
            let key = name.lowercased()
            guard !seen.contains(key) else {
                throw LinkCError.parse("system-map.json names \"\(name)\" twice")
            }
            seen.insert(key)

            let context = "component \"\(name)\" in system-map.json"
            var component = SystemComponent(
                name: name,
                kind: ComponentKind(try string(raw, "kind", context: context) ?? ComponentKind.service.raw),
                reachedBy: try string(raw, "reached_by", context: context),
                runs: try string(raw, "runs", context: context),
                usedBy: try stringArray(raw, "used_by", context: context) ?? [],
                intended: try bool(raw, "intended", context: context) ?? false,
                at: try gridPoint(raw, context: context))
            do {
                component.extras = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            } catch {
                throw LinkCError.parse("\(context) could not be recorded verbatim: \(error.localizedDescription)")
            }
            components.append(component)
        }

        var rootExtras = root
        rootExtras.removeValue(forKey: "components")
        rootExtras.removeValue(forKey: "version")
        var map = SystemMap(
            version: try int(root, "version", context: "system-map.json") ?? 1,
            components: components)
        do {
            map.extras = try JSONSerialization.data(withJSONObject: rootExtras, options: [.sortedKeys])
        } catch {
            throw LinkCError.parse("system-map.json could not be recorded verbatim: \(error.localizedDescription)")
        }
        return map
    }

    /// A known key that is present but not the format's type for it refuses the whole file —
    /// an absent key is unaffected and keeps its default.
    private static func string(_ raw: [String: Any], _ key: String, context: String) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let string = value as? String else {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not text")
        }
        return string
    }

    private static func bool(_ raw: [String: Any], _ key: String, context: String) throws -> Bool? {
        guard let value = raw[key] else { return nil }
        guard let bool = value as? Bool else {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not true or false")
        }
        return bool
    }

    private static func int(_ raw: [String: Any], _ key: String, context: String) throws -> Int? {
        guard let value = raw[key] else { return nil }
        guard let int = value as? Int else {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not a whole number")
        }
        return int
    }

    private static func stringArray(_ raw: [String: Any], _ key: String, context: String) throws -> [String]? {
        guard let value = raw[key] else { return nil }
        guard let array = value as? [String] else {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not a list of text")
        }
        return array
    }

    /// `at` must carry both `x` and `y` as whole numbers or the file is refused — a half-formed
    /// position is not a usable one.
    private static func gridPoint(_ raw: [String: Any], context: String) throws -> GridPoint? {
        guard let value = raw["at"] else { return nil }
        guard let point = value as? [String: Any],
              let x = point["x"] as? Int, let y = point["y"] as? Int else {
            throw LinkCError.parse("\(context) has \"at\" but it needs whole-number x and y")
        }
        return GridPoint(x: x, y: y)
    }

    /// The file's bytes, keeping every key linkC does not know and omitting empty fields.
    public func encoded() throws -> Data {
        var root = try extrasObject(extras, context: "the system map's own extras")
        root["version"] = version
        root["components"] = try components.map { component in
            var object = try extrasObject(component.extras, context: "component \"\(component.name)\"'s extras")
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

    /// Reads a stored `extras` blob back into the object it was serialized from. Unknown keys
    /// surviving an edit is the one guarantee this type makes; silently dropping them here (the
    /// old behaviour, via `try?` defaulting to `[:]`) would let a write go ahead anyway and
    /// quietly lose them, which is exactly the kind of silent data loss this must never allow.
    private func extrasObject(_ data: Data?, context: String) throws -> [String: Any] {
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

    /// Writes a value, or removes the key when it is nil or blank — an absent field is absent,
    /// never `null` and never `""`.
    private func set(_ object: inout [String: Any], _ key: String, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { object.removeValue(forKey: key) } else { object[key] = trimmed }
    }
}
