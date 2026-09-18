import Foundation

/// Pre-seeds directory trust in `~/.claude.json` so CLI sessions never block on
/// interactive directory trust dialogs.
public enum DirectoryTrustManager: Sendable {
    public static func preApproveTrust(workspacePath: String, claudeJsonURL: URL? = nil) throws {
        let fileURL = claudeJsonURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let norm = (workspacePath as NSString).standardizingPath

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        } else {
            root = [
                "projects": [String: Any](),
                "trustedDirectories": [String]()
            ]
        }

        var projects = root["projects"] as? [String: Any] ?? [:]
        var projectConfig = projects[norm] as? [String: Any] ?? [:]
        projectConfig["hasTrustDialogAccepted"] = true
        projects[norm] = projectConfig
        root["projects"] = projects

        if var trusted = root["trustedDirectories"] as? [String] {
            if !trusted.contains(norm) {
                trusted.append(norm)
            }
            root["trustedDirectories"] = trusted
        } else {
            root["trustedDirectories"] = [norm]
        }

        let parentDir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    /// Pre-seeds Codex's folder trust — `[projects."<path>"] trust_level = "trusted"` in
    /// `~/.codex/config.toml` — so a Codex session never opens on its trust dialog. Appends only:
    /// every existing line is kept as it was, and a folder already listed is left alone, since an
    /// entry there (even `untrusted`) is the user's own choice.
    public static func preApproveCodexTrust(workspacePath: String, configURL: URL? = nil) throws {
        let fileURL = configURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        let norm = (workspacePath as NSString).standardizingPath
        let escaped = norm.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let header = "[projects.\"\(escaped)\"]"

        var content = ""
        if FileManager.default.fileExists(atPath: fileURL.path) {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        }
        guard !content.contains(header) else { return }

        if !content.isEmpty {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n"
        }
        content += "\(header)\ntrust_level = \"trusted\"\n"
        try write(Data(content.utf8), to: fileURL)
    }

    /// Pre-seeds Antigravity's folder trust — `trustedWorkspaces` in
    /// `~/.gemini/antigravity-cli/settings.json`. agy trusts each exact folder (a subfolder of a
    /// trusted one still asks), so the launch folder itself is listed. Other settings are kept, a
    /// folder already listed means no write at all, and a file that cannot be parsed is never
    /// overwritten: that would erase the user's own settings.
    public static func preApproveAgyTrust(workspacePath: String, settingsURL: URL? = nil) throws {
        let fileURL = settingsURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let norm = (workspacePath as NSString).standardizingPath

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw LinkCError.parse("\(fileURL.path) is not a JSON object")
                }
                root = object
            }
        }

        var trusted = root["trustedWorkspaces"] as? [String] ?? []
        guard !trusted.contains(norm) else { return }
        trusted.append(norm)
        root["trustedWorkspaces"] = trusted
        try write(try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: fileURL)
    }

    private static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
}
