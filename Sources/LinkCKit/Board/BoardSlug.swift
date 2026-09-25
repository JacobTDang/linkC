import Foundation

/// Names the detail-board files. A detail board's slug is the chain of part names from the
/// overview, each made lowercase words joined by "-", and joined by ".".
public enum BoardSlug {
    /// One name's slug. Whitespace, "-" and "_" separate words; every other character outside
    /// a-z and 0-9 is dropped. A name with nothing left is "part".
    public static func part(_ name: String) -> String {
        var slug = ""
        var pendingDash = false
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.append(character)
                pendingDash = false
            } else if character.isWhitespace || character == "-" || character == "_" {
                pendingDash = true
            }
        }
        return slug.isEmpty ? "part" : slug
    }

    /// The slug for a new detail board of `name` on the board `parent` (nil is the overview),
    /// unique among `taken`: "-2", "-3" … is added when needed.
    public static func new(for name: String, under parent: String?, taken: Set<String>) -> String {
        let base = (parent.map { $0 + "." } ?? "") + part(name)
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// Whether a slug from outside is well formed: only a-z, 0-9, "-" and ".", no empty
    /// segment, so no path can escape the project folder.
    public static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard slug.allSatisfy({ allowed.contains($0) }) else { return false }
        return !slug.split(separator: ".", omittingEmptySubsequences: false).contains { $0.isEmpty }
    }

    /// The board's file name. nil is the overview.
    public static func fileName(for slug: String?) -> String {
        slug.map { "system-map.\($0).json" } ?? "system-map.json"
    }

    /// The slug in a detail board's file name, or nil for anything else, including the overview.
    public static func slug(fromFileName name: String) -> String? {
        guard name.hasPrefix("system-map."), name.hasSuffix(".json"), name != "system-map.json" else { return nil }
        let slug = String(name.dropFirst("system-map.".count).dropLast(".json".count))
        return isValid(slug) ? slug : nil
    }
}
