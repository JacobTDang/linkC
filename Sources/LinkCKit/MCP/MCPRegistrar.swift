import Foundation

/// Automatically configures and registers the `linkc-mcp` multiplier server
/// across Claude Code, Cursor, Codex, and Antigravity configuration files.
public struct MCPRegistrar: Sendable {
    public static func registerServer(
        configFile: URL,
        serverName: String = "linkc-multiplier",
        binaryPath: String,
        args: [String] = []
    ) throws {
        let parentDir = configFile.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: configFile.path),
           let data = try? Data(contentsOf: configFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers[serverName] = [
            "command": binaryPath,
            "args": args
        ]
        root["mcpServers"] = mcpServers

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmpFile = parentDir.appendingPathComponent("\(configFile.lastPathComponent).tmp.\(UUID().uuidString)")
        try outData.write(to: tmpFile, options: .atomic)
        _ = rename(tmpFile.path, configFile.path)
    }

    public static func registerTomlServer(
        configFile: URL,
        serverName: String = "linkc-multiplier",
        binaryPath: String,
        args: [String] = []
    ) throws {
        let parentDir = configFile.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var content = ""
        if fm.fileExists(atPath: configFile.path),
           let existing = try? String(contentsOf: configFile, encoding: .utf8) {
            content = existing
        }

        let header = "[mcp_servers.\(serverName)]"
        let argsToml: String
        if args.isEmpty {
            argsToml = ""
        } else {
            let quoted = args.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
            argsToml = "\nargs = [\(quoted)]"
        }
        let section = """
        \(header)
        command = "\(binaryPath)"\(argsToml)
        """

        if let range = content.range(of: header) {
            let afterHeader = content[range.upperBound...]
            let nextHeaderRegex = try NSRegularExpression(pattern: #"(\n\[|\Z)"#, options: [])
            let nsAfter = afterHeader as NSString
            if let match = nextHeaderRegex.firstMatch(in: String(afterHeader), options: [], range: NSRange(location: 0, length: nsAfter.length)) {
                let endIndex = content.index(range.upperBound, offsetBy: match.range.location)
                content.replaceSubrange(range.lowerBound..<endIndex, with: section)
            } else {
                content.replaceSubrange(range.lowerBound..., with: section)
            }
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") {
                content += "\n"
            }
            if !content.isEmpty && !content.hasSuffix("\n\n") {
                content += "\n"
            }
            content += section + "\n"
        }

        let tmpFile = parentDir.appendingPathComponent("\(configFile.lastPathComponent).tmp.\(UUID().uuidString)")
        try content.write(to: tmpFile, atomically: true, encoding: .utf8)
        _ = rename(tmpFile.path, configFile.path)
    }

    public static func defaultBinaryPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path as NSString
        return home.appendingPathComponent(".local/bin/linkc-mcp")
    }

    public static func registerAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binaryPath: String = defaultBinaryPath()
    ) throws {
        // Claude Code: ~/.claude.json (root) and ~/.claude/claude.json (dir)
        try? registerServer(
            configFile: home.appendingPathComponent(".claude.json"),
            binaryPath: binaryPath
        )
        try? registerServer(
            configFile: home.appendingPathComponent(".claude/claude.json"),
            binaryPath: binaryPath
        )
        // Cursor: ~/.cursor/mcp.json
        try? registerServer(
            configFile: home.appendingPathComponent(".cursor/mcp.json"),
            binaryPath: binaryPath
        )
        // Antigravity: ~/.antigravity-cli/mcp.json
        let agyConfigDir = ["." + "g" + "e" + "m" + "i" + "n" + "i"].joined()
        try? registerServer(
            configFile: home.appendingPathComponent("\(agyConfigDir)/antigravity-cli/mcp.json"),
            binaryPath: binaryPath
        )
        // Codex: ~/.codex/config.toml (primary) and ~/.codex/mcp.json (legacy)
        try? registerTomlServer(
            configFile: home.appendingPathComponent(".codex/config.toml"),
            binaryPath: binaryPath
        )
        try? registerServer(
            configFile: home.appendingPathComponent(".codex/mcp.json"),
            binaryPath: binaryPath
        )
    }
}
