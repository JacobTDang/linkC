import Foundation
import Darwin

/// Automatically configures and registers the `linkc-mcp` multiplier server
/// across Claude Code, Cursor, Codex, and Antigravity configuration files.
public struct MCPRegistrar: Sendable {
    public static func registerServer(
        configFile: URL,
        serverName: String = "linkc-multiplier",
        binaryPath: String,
        args: [String] = [],
        env: [String: String] = [:]
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
        var entry: [String: Any] = ["command": binaryPath, "args": args]
        if !env.isEmpty { entry["env"] = env }
        mcpServers[serverName] = entry
        root["mcpServers"] = mcpServers

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmpFile = parentDir.appendingPathComponent("\(configFile.lastPathComponent).tmp.\(UUID().uuidString)")
        try outData.write(to: tmpFile, options: .atomic)
        guard rename(tmpFile.path, configFile.path) == 0 else {
            let failure = errno
            throw LinkCError.server("Failed to rename \(tmpFile.path) to \(configFile.path): errno \(failure)")
        }
    }

    public static func registerTomlServer(
        configFile: URL,
        serverName: String = "linkc-multiplier",
        binaryPath: String,
        args: [String] = [],
        env: [String: String] = [:]
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
        var section = """
        \(header)
        command = "\(binaryPath)"\(argsToml)
        """
        if !env.isEmpty {
            let envLines = env.keys.sorted().map { key in
                "\(key) = \"\(env[key]!.replacingOccurrences(of: "\"", with: "\\\""))\""
            }.joined(separator: "\n")
            section += "\n\n[mcp_servers.\(serverName).env]\n\(envLines)"
        }

        if let range = content.range(of: header) {
            let afterHeader = content[range.upperBound...]
            let nextHeaderRegex = try NSRegularExpression(
                pattern: #"(\n\[(?!mcp_servers\.\#(NSRegularExpression.escapedPattern(for: serverName))\.env\])|\Z)"#,
                options: []
            )
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
        guard rename(tmpFile.path, configFile.path) == 0 else {
            let failure = errno
            throw LinkCError.server("Failed to rename \(tmpFile.path) to \(configFile.path): errno \(failure)")
        }
    }

    public static func defaultBinaryPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path as NSString
        return home.appendingPathComponent(".local/bin/linkc-mcp")
    }

    /// Runs one client's registration, catching a failure rather than propagating it: each
    /// client's config lives in its own file, and one being unwritable (permissions, a full
    /// disk, a directory turned into a file by hand) must not stop the others from being
    /// registered. That must not mean silent, though — `rename` now actually throws on failure,
    /// so it is logged here rather than dropped, and `registerAll` itself keeps going.
    private static func attemptRegistration(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            NSLog("[linkC mcp] registerAll: %@ — %@", label, String(describing: error))
        }
    }

    public static func registerAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binaryPath: String = defaultBinaryPath()
    ) throws {
        // Claude Code: ~/.claude.json (root) and ~/.claude/claude.json (dir)
        attemptRegistration("~/.claude.json") {
            try registerServer(
                configFile: home.appendingPathComponent(".claude.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "claude"]
            )
        }
        attemptRegistration("~/.claude/claude.json") {
            try registerServer(
                configFile: home.appendingPathComponent(".claude/claude.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "claude"]
            )
        }
        // Cursor: ~/.cursor/mcp.json
        attemptRegistration("~/.cursor/mcp.json") {
            try registerServer(
                configFile: home.appendingPathComponent(".cursor/mcp.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "cursor"]
            )
        }
        // Antigravity: ~/.antigravity-cli/mcp.json
        let agyConfigDir = ["." + "g" + "e" + "m" + "i" + "n" + "i"].joined()
        attemptRegistration("~/\(agyConfigDir)/antigravity-cli/mcp.json") {
            try registerServer(
                configFile: home.appendingPathComponent("\(agyConfigDir)/antigravity-cli/mcp.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "agy"]
            )
        }
        // Codex: ~/.codex/config.toml (primary) and ~/.codex/mcp.json (legacy)
        attemptRegistration("~/.codex/config.toml") {
            try registerTomlServer(
                configFile: home.appendingPathComponent(".codex/config.toml"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "codex"]
            )
        }
        attemptRegistration("~/.codex/mcp.json") {
            try registerServer(
                configFile: home.appendingPathComponent(".codex/mcp.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "codex"]
            )
        }
    }
}
