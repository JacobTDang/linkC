import Foundation
import Darwin

/// Automatically configures and registers the `linkc-mcp` multiplier server
/// across Claude Code, Cursor, Codex, and Antigravity configuration files.
public struct MCPRegistrar: Sendable {
    /// The name linkC's tool server is registered under in every agent's config.
    public static let serverName = "linkc-multiplier"

    public static func registerServer(
        configFile: URL,
        serverName: String = MCPRegistrar.serverName,
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
        serverName: String = MCPRegistrar.serverName,
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

    /// Runs one client's registration, turning a thrown failure into a labeled description
    /// instead of propagating it immediately: each client's config lives in its own file, and
    /// one being unwritable (permissions, a full disk, a directory turned into a file by hand)
    /// must not stop the others from being attempted. The failure is still logged here, and
    /// also handed back so `registerAll` can name it in what it throws once every client has
    /// had its turn.
    private static func attemptRegistration(_ label: String, _ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            let description = String(describing: error)
            NSLog("[linkC mcp] registerAll: %@ — %@", label, description)
            return "\(label): \(description)"
        }
    }

    public static func registerAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binaryPath: String = defaultBinaryPath()
    ) throws {
        var failures: [String] = []

        // Claude Code: ~/.claude.json (root) and ~/.claude/claude.json (dir)
        if let f = attemptRegistration("~/.claude.json", {
            try registerServer(
                configFile: home.appendingPathComponent(".claude.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "claude"]
            )
        }) { failures.append(f) }
        if let f = attemptRegistration("~/.claude/claude.json", {
            try registerServer(
                configFile: home.appendingPathComponent(".claude/claude.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "claude"]
            )
        }) { failures.append(f) }
        // Cursor: ~/.cursor/mcp.json
        if let f = attemptRegistration("~/.cursor/mcp.json", {
            try registerServer(
                configFile: home.appendingPathComponent(".cursor/mcp.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "cursor"]
            )
        }) { failures.append(f) }
        // Antigravity: ~/.gemini/config/mcp_config.json (global) and ~/.gemini/antigravity-cli/mcp.json
        let agyConfigDir = ["." + "g" + "e" + "m" + "i" + "n" + "i"].joined()
        if let f = attemptRegistration("~/\(agyConfigDir)/config/mcp_config.json", {
            try registerServer(
                configFile: home.appendingPathComponent("\(agyConfigDir)/config/mcp_config.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "agy"]
            )
        }) { failures.append(f) }
        if let f = attemptRegistration("~/\(agyConfigDir)/antigravity-cli/mcp.json", {
            try registerServer(
                configFile: home.appendingPathComponent("\(agyConfigDir)/antigravity-cli/mcp.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "agy"]
            )
        }) { failures.append(f) }
        // Codex: ~/.codex/config.toml (primary) and ~/.codex/mcp.json (legacy)
        if let f = attemptRegistration("~/.codex/config.toml", {
            try registerTomlServer(
                configFile: home.appendingPathComponent(".codex/config.toml"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "codex"]
            )
        }) { failures.append(f) }
        if let f = attemptRegistration("~/.codex/mcp.json", {
            try registerServer(
                configFile: home.appendingPathComponent(".codex/mcp.json"),
                binaryPath: binaryPath,
                env: ["LINKC_AGENT": "codex"]
            )
        }) { failures.append(f) }

        guard failures.isEmpty else {
            throw LinkCError.server("failed to register with: \(failures.joined(separator: "; "))")
        }
    }
}
