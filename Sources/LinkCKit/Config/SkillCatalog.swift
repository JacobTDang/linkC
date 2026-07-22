import Foundation

/// One skill in the unified list, from either source.
public struct SkillEntry: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case user
        case plugin(InstalledPlugin)
    }

    public let name: String
    public let description: String
    public let source: Source
    /// The SKILL.md's containing folder — the Reveal-in-Finder target and the identity key.
    public let path: String
    public let usageCount: Int
    public let lastUsedAt: Date?

    public var id: String { path }
}

/// Pure merge of user + plugin skills with usage stats: usage-count descending, then name.
/// Dedupe is by path — the same plugin installed at two scopes points at one install dir and
/// must not render twice; a genuine version conflict (different paths) stays visible.
public enum SkillCatalog {
    public static func merge(
        userSkills: [(path: String, frontmatter: SkillFrontmatter)],
        pluginSkills: [(plugin: InstalledPlugin, path: String, frontmatter: SkillFrontmatter)],
        usage: [String: ClaudeUserConfig.UsageStat]
    ) -> [SkillEntry] {
        var seenPaths = Set<String>()
        var entries: [SkillEntry] = []

        for skill in userSkills where seenPaths.insert(skill.path).inserted {
            let stat = usage[skill.frontmatter.name]
            entries.append(SkillEntry(
                name: skill.frontmatter.name,
                description: skill.frontmatter.description,
                source: .user,
                path: skill.path,
                usageCount: stat?.usageCount ?? 0,
                lastUsedAt: stat?.lastUsedAt
            ))
        }

        for skill in pluginSkills where seenPaths.insert(skill.path).inserted {
            // skillUsage keys plugin skills as "<pluginName>:<skillName>".
            let stat = usage["\(skill.plugin.bareName):\(skill.frontmatter.name)"]
            entries.append(SkillEntry(
                name: skill.frontmatter.name,
                description: skill.frontmatter.description,
                source: .plugin(skill.plugin),
                path: skill.path,
                usageCount: stat?.usageCount ?? 0,
                lastUsedAt: stat?.lastUsedAt
            ))
        }

        return entries.sorted {
            $0.usageCount != $1.usageCount ? $0.usageCount > $1.usageCount : $0.name < $1.name
        }
    }
}
