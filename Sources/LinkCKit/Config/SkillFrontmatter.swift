import Foundation

public struct SkillFrontmatter: Equatable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// Line-based SKILL.md frontmatter parsing — every real skill on disk uses single-line
/// `name:`/`description:` scalars, so a YAML dependency isn't warranted. A skill this can't
/// read confidently (folded YAML, missing fields) returns nil and is skipped from the list —
/// dropped, never mis-rendered.
public enum SkillFrontmatterParser {
    public static func parse(_ contents: String) -> SkillFrontmatter? {
        let lines = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }

        guard let name = fields["name"], !name.isEmpty,
              let description = fields["description"], !description.isEmpty else { return nil }
        return SkillFrontmatter(name: name, description: description)
    }
}
