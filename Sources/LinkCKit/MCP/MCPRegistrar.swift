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

    public static func defaultBinaryPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path as NSString
        return home.appendingPathComponent(".local/bin/linkc-mcp")
    }

    public static func registerAll(binaryPath: String = defaultBinaryPath()) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Claude Code: ~/.claude/claude.json
        try? registerServer(
            configFile: home.appendingPathComponent(".claude/claude.json"),
            binaryPath: binaryPath
        )
        // Cursor: ~/.cursor/mcp.json
        try? registerServer(
            configFile: home.appendingPathComponent(".cursor/mcp.json"),
            binaryPath: binaryPath
        )
        // Antigravity: ~/.gemini/antigravity-cli/mcp.json
        try? registerServer(
            configFile: home.appendingPathComponent(".gemini/antigravity-cli/mcp.json"),
            binaryPath: binaryPath
        )
        // Codex: ~/.codex/mcp.json
        try? registerServer(
            configFile: home.appendingPathComponent(".codex/mcp.json"),
            binaryPath: binaryPath
        )
    }
}
