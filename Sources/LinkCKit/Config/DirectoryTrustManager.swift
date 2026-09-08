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
}
