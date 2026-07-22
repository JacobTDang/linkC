import Foundation

/// Filesystem skill enumeration. The filter is SKILL.md presence — skill directories share
/// their parent with non-skill workspaces on real machines, and only real skills may render.
/// Missing directories read as empty, not as errors (a fresh install has no skills).
public struct SkillDiscovery: Sendable {
    public let userSkillsDir: URL

    public init(
        userSkillsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills")
    ) {
        self.userSkillsDir = userSkillsDir
    }

    public func userSkills() -> [(path: String, frontmatter: SkillFrontmatter)] {
        skills(in: userSkillsDir)
    }

    /// `<installPath>/skills/*/SKILL.md` — installPath comes from `claude plugin list`,
    /// which already resolves past orphaned version directories.
    public func pluginSkills(installPath: String) -> [(path: String, frontmatter: SkillFrontmatter)] {
        skills(in: URL(fileURLWithPath: installPath).appendingPathComponent("skills"))
    }

    private func skills(in directory: URL) -> [(path: String, frontmatter: SkillFrontmatter)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { dir in
                let skillFile = dir.appendingPathComponent("SKILL.md")
                guard let contents = try? String(contentsOf: skillFile, encoding: .utf8),
                      let frontmatter = SkillFrontmatterParser.parse(contents) else { return nil }
                return (path: dir.path, frontmatter: frontmatter)
            }
            .sorted { $0.path < $1.path }
    }
}
