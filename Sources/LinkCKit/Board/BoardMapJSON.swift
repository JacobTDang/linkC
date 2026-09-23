import Foundation

/// A small deterministic writer for `system-map.json`: the architecture-first key order at the
/// top, sorted keys everywhere else (see `sortedKeys`),
/// 2-space indentation, number arrays kept to one line, `/` left unescaped, and a single trailing
/// newline — so moving one box on the board changes exactly one line of the file.
enum BoardMapJSON {
    /// The top level's fixed order. Anything linkC does not know sorts after these and before
    /// `layout`, which always comes last.
    private static let rootOrder = ["version", "system", "places", "notes"]

    static func write(_ root: [String: Any]) throws -> Data {
        let text = try object(root, keys: orderedRootKeys(root), indent: 0) + "\n"
        guard let data = text.data(using: .utf8) else {
            throw LinkCError.parse("failed to write the system map: the text was not valid UTF-8")
        }
        return data
    }

    private static func orderedRootKeys(_ root: [String: Any]) -> [String] {
        var keys = rootOrder.filter { root[$0] != nil }
        let known = Set(rootOrder + ["layout"])
        keys += sortedKeys(root.keys.filter { !known.contains($0) })
        if root["layout"] != nil { keys.append("layout") }
        return keys
    }

    /// Case-insensitive with numbers by value ("api-2" before "api-10"), and no locale, so every
    /// Mac writes the same order. `.forcedOrdering` breaks a case-only tie so the sort is total.
    private static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { $0.compare($1, options: [.caseInsensitive, .numeric, .forcedOrdering]) == .orderedAscending }
    }

    private static func indent(_ level: Int) -> String { String(repeating: "  ", count: level) }

    private static func object(_ dict: [String: Any], keys: [String], indent level: Int) throws -> String {
        guard !keys.isEmpty else { return "{}" }
        let childIndent = indent(level + 1)
        let lines = try keys.map { key -> String in
            "\(childIndent)\(try quotedString(key)): \(try render(dict[key] ?? NSNull(), indent: level + 1))"
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n\(indent(level))}"
    }

    private static func render(_ value: Any, indent level: Int) throws -> String {
        switch value {
        case let dict as [String: Any]:
            return try object(dict, keys: sortedKeys(dict.keys), indent: level)
        case is NSNull:
            return "null"
        case let array as [Any]:
            return try renderArray(array, indent: level)
        default:
            return try scalar(value)
        }
    }

    /// An array of nothing but numbers stays on one line, e.g. `[64, 128]`; anything else —
    /// strings, booleans, nulls, nested arrays or objects — goes one element per line.
    private static func renderArray(_ array: [Any], indent level: Int) throws -> String {
        guard !array.isEmpty else { return "[]" }
        if array.allSatisfy(isPlainNumber) {
            return "[" + (try array.map { try scalar($0) }).joined(separator: ", ") + "]"
        }
        let childIndent = indent(level + 1)
        let lines = try array.map { "\(childIndent)\(try render($0, indent: level + 1))" }
        return "[\n" + lines.joined(separator: ",\n") + "\n\(indent(level))]"
    }

    private static func isPlainNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return !isBoolNumber(number)
    }

    /// An `NSNumber` decoded from JSON `true`/`false` carries the `CFBoolean` type, not a plain
    /// numeric one — checking `is Bool` here is not reliable: any `NSNumber` from
    /// `JSONSerialization`, integer or not, answers `true` to that cast.
    private static func isBoolNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func quotedString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw LinkCError.parse("failed to write the system map: a string could not be encoded")
        }
        return text
    }

    /// A leaf `JSONSerialization` would print bare — a string, a number or a bool — written
    /// exactly as it would write it, so a boolean stays `true`, never `1`.
    private static func scalar(_ value: Any) throws -> String {
        if let text = value as? String { return try quotedString(text) }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw LinkCError.parse("failed to write the system map: a value could not be encoded")
        }
        return text
    }
}
