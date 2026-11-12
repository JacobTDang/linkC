import Foundation
import Darwin

/// Automatically configures and registers the `linkc-mcp` multiplier server
/// across Claude Code, Cursor, Codex, Antigravity, OpenCode, Freebuff, Kilo, and Crush configuration files.
public struct MCPRegistrar: Sendable {
    /// The name linkC's tool server is registered under in every agent's config.
    public static let serverName = "linkc-multiplier"

    /// The JSON object in `configFile`; an empty one when the file is missing or holds only
    /// whitespace. Anything else that is not a JSON object — comments, a trailing comma, a
    /// half-written file — throws, so no caller ever replaces a file it could not read.
    static func readJSONObject(at configFile: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return [:] }
        let data = try Data(contentsOf: configFile)
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.server("\(configFile.path) is not JSON linkC can read, so it was left untouched — \(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw LinkCError.server("\(configFile.path) does not hold a JSON object, so it was left untouched")
        }
        return object
    }

    /// Writes `data` to `configFile` through a temporary file beside it and one rename. A config
    /// that is a symlink (dotfile repos keep them that way) is written through to the file it
    /// points at, so the link stays a link, and an existing file keeps its permissions — a config
    /// holding provider keys is often private to its owner. A write or rename that fails removes
    /// the temporary file and rethrows.
    private static func writeAtomically(_ data: Data, to configFile: URL) throws {
        let fm = FileManager.default
        let target = configFile.resolvingSymlinksInPath()
        let parentDir = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        let permissions = fm.fileExists(atPath: target.path)
            ? try fm.attributesOfItem(atPath: target.path)[.posixPermissions]
            : nil
        let tmpFile = parentDir.appendingPathComponent("\(target.lastPathComponent).tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tmpFile, options: .atomic)
            if let permissions {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmpFile.path)
            }
            guard rename(tmpFile.path, target.path) == 0 else {
                let failure = errno
                throw LinkCError.server("Failed to rename \(tmpFile.path) to \(target.path): errno \(failure)")
            }
        } catch {
            try discard(tmpFile, after: error)
        }
    }

    /// Removes the temporary file a failed write left and rethrows `failure`; when the file cannot
    /// be removed either, the error says so, naming it.
    private static func discard(_ tmpFile: URL, after failure: Error) throws -> Never {
        if FileManager.default.fileExists(atPath: tmpFile.path) {
            do {
                try FileManager.default.removeItem(at: tmpFile)
            } catch {
                throw LinkCError.server("\(failure) — and \(tmpFile.path) could not be removed: \(error.localizedDescription)")
            }
        }
        throw failure
    }

    /// The text of the UTF-8 file at `configFile`; empty when there is no such file. A file that
    /// cannot be read, or is not UTF-8, throws naming it, so no caller replaces a file it could
    /// not read.
    private static func readText(at configFile: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return "" }
        let data: Data
        do {
            data = try Data(contentsOf: configFile)
        } catch {
            throw LinkCError.server("\(configFile.path) cannot be read, so it was left untouched — \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LinkCError.server("\(configFile.path) is not UTF-8 text linkC can read, so it was left untouched")
        }
        return text
    }

    public static func registerServer(
        configFile: URL,
        serverName: String = MCPRegistrar.serverName,
        binaryPath: String,
        args: [String] = [],
        env: [String: String] = [:]
    ) throws {
        var root = try readJSONObject(at: configFile)
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": binaryPath, "args": args]
        if !env.isEmpty { entry["env"] = env }
        mcpServers[serverName] = entry
        root["mcpServers"] = mcpServers
        try writeAtomically(try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: configFile)
    }

    public static func freebuffConfigFile(home: URL) -> URL {
        home.appendingPathComponent(".agents/mcp.json")
    }

    public static func registerFreebuffServer(
        configFile: URL,
        serverName: String = MCPRegistrar.serverName,
        binaryPath: String
    ) throws {
        try registerServer(
            configFile: configFile,
            serverName: serverName,
            binaryPath: binaryPath,
            env: ["LINKC_AGENT": AgentKind.freebuff.rawValue])
    }

    /// OpenCode's global config file.
    public static func openCodeConfigFile(home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/opencode.json")
    }

    /// Kilo's global config file under `home`: prefer `kilo.jsonc` when it exists, else `kilo.json`
    /// when that exists, else the path where a new `kilo.jsonc` will be created.
    public static func kiloConfigFile(home: URL) -> URL {
        let dir = home.appendingPathComponent(".config/kilo", isDirectory: true)
        let jsonc = dir.appendingPathComponent("kilo.jsonc")
        let json = dir.appendingPathComponent("kilo.json")
        let fm = FileManager.default
        if fm.fileExists(atPath: jsonc.path) { return jsonc }
        if fm.fileExists(atPath: json.path) { return json }
        return jsonc
    }

    /// linkC's server as an entry of OpenCode's `mcp` table — OpenCode's own shape, not `mcpServers`.
    public static func openCodeEntry(binaryPath: String) -> [String: Any] {
        openCodeStyleEntry(binaryPath: binaryPath, agent: .opencode)
    }

    /// linkC's server as an entry of Kilo's `mcp` table — same shape as OpenCode's.
    public static func kiloEntry(binaryPath: String) -> [String: Any] {
        openCodeStyleEntry(binaryPath: binaryPath, agent: .kilo)
    }

    private static func openCodeStyleEntry(binaryPath: String, agent: AgentKind) -> [String: Any] {
        ["type": "local", "command": [binaryPath],
         "environment": ["LINKC_AGENT": agent.rawValue], "enabled": true]
    }

    /// `root`'s `mcp` table: empty when it has none; throws when it has one that is not a table.
    private static func mcpTable(in root: [String: Any], of source: String) throws -> [String: Any] {
        switch root["mcp"] {
        case nil: return [:]
        case let table as [String: Any]: return table
        default: throw LinkCError.server("\(source) has an \"mcp\" that is not a table, so linkC left it untouched")
        }
    }

    /// `value` of `key` in `source`: empty when it is absent; throws when it is not a table.
    private static func table(_ value: Any?, key: String, of source: String) throws -> [String: Any] {
        switch value {
        case nil: return [:]
        case let table as [String: Any]: return table
        default: throw LinkCError.process("\(source) has \"\(key)\" that is not a table, so linkC cannot pin its model")
        }
    }

    /// Registers linkC's server in OpenCode's config, keeping every other key. Writes only when the
    /// entry differs from the one already there, and never over a file it could not read.
    public static func registerOpenCodeServer(configFile: URL, serverName: String = MCPRegistrar.serverName, binaryPath: String) throws {
        try registerOpenCodeStyleServer(
            configFile: configFile, serverName: serverName, entry: openCodeEntry(binaryPath: binaryPath))
    }

    /// Registers linkC's server in Kilo's config under `mcp`, in OpenCode's shape. Same merge and
    /// JSONC rules as OpenCode: keeps every other key, skips a rewrite when the entry is unchanged,
    /// and never overwrites a file that is not plain JSON.
    public static func registerKiloServer(configFile: URL, serverName: String = MCPRegistrar.serverName, binaryPath: String) throws {
        try registerOpenCodeStyleServer(
            configFile: configFile, serverName: serverName, entry: kiloEntry(binaryPath: binaryPath))
    }

    /// Shared writer for OpenCode-style `mcp` tables (OpenCode and Kilo).
    private static func registerOpenCodeStyleServer(
        configFile: URL, serverName: String, entry: [String: Any]
    ) throws {
        var root = try readJSONObject(at: configFile)
        var mcp = try mcpTable(in: root, of: configFile.path)
        if let existing = mcp[serverName] as? [String: Any], NSDictionary(dictionary: existing).isEqual(to: entry) { return }
        mcp[serverName] = entry
        root["mcp"] = mcp
        try writeAtomically(
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            to: configFile)
    }

    /// Crush's global config file: `crush.json` in the folder `CRUSH_GLOBAL_CONFIG` or
    /// `XDG_CONFIG_HOME` names, else `~/.config/crush/crush.json` — the file Crush itself reads, and
    /// the one a session's pinned copy is made from.
    public static func crushConfigFile(home: URL, environment: [String: String]) -> URL {
        CrushDirectories.standard(home: home, environment: environment).config.appendingPathComponent("crush.json")
    }

    /// linkC's server as an entry of Crush's `mcp` table.
    public static func crushEntry(binaryPath: String) -> [String: Any] {
        ["type": "stdio", "command": binaryPath, "args": [String](),
         "env": ["LINKC_AGENT": AgentKind.crush.rawValue]]
    }

    /// Registers linkC's server in Crush's config, keeping every other key and server. Writes only
    /// when the entry differs from the one already there, and never over a file it could not read.
    public static func registerCrushServer(configFile: URL, serverName: String = MCPRegistrar.serverName, binaryPath: String) throws {
        var root = try readJSONObject(at: configFile)
        var mcp = try mcpTable(in: root, of: configFile.path)
        let entry = crushEntry(binaryPath: binaryPath)
        if let existing = mcp[serverName] as? [String: Any], NSDictionary(dictionary: existing).isEqual(to: entry) { return }
        mcp[serverName] = entry
        root["mcp"] = mcp
        try writeAtomically(
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            to: configFile)
    }

    /// `OPENCODE_CONFIG_CONTENT` for a terminal linkC starts OpenCode in: `inherited` — a value
    /// already in linkC's own environment — with linkC's server added to its `mcp` table and, when
    /// given, `model` as the session's model, on top level and on every agent that runs on it (a
    /// user-global `agent.build.model` would otherwise beat the top-level one). One line.
    /// Throws when `inherited` is not a JSON object.
    public static func openCodeConfigContent(inherited: String?, binaryPath: String, model: String?) throws -> String {
        try inlineOpenCodeStyleConfigContent(
            inherited: inherited,
            source: "\(AgentDescriptor.openCodeConfigContentKey) in linkC's environment",
            entry: openCodeEntry(binaryPath: binaryPath),
            model: model,
            agents: AgentDescriptor.openCodeAgents)
    }

    /// `KILO_CONFIG_CONTENT` for a terminal linkC starts Kilo in — same shape as OpenCode's inline
    /// config. Complements `registerKiloServer`, which merges into the on-disk global file.
    /// Kilo takes an agent's own `model` ahead of the pick it persisted and the top-level `model`, so
    /// `model` is on every agent as well as on top level, and `smallModel` replaces Kilo's own small
    /// model, which is not free. Both must be free ids: the caller checks.
    public static func kiloConfigContent(inherited: String?, binaryPath: String, model: String, smallModel: String) throws -> String {
        try inlineOpenCodeStyleConfigContent(
            inherited: inherited,
            source: "\(AgentDescriptor.kiloConfigContentKey) in linkC's environment",
            entry: kiloEntry(binaryPath: binaryPath),
            model: model,
            smallModel: smallModel,
            agents: AgentDescriptor.kiloAgents)
    }

    /// Shared JSON builder for OpenCode-style inline config: `mcp`, and the model pinned when given — on
    /// top level, as `small_model` when `smallModel` is, and as the model of each of `agents`. One line.
    private static func inlineOpenCodeStyleConfigContent(
        inherited: String?,
        source: String,
        entry: [String: Any],
        model: String?,
        smallModel: String? = nil,
        agents: [String]
    ) throws -> String {
        var root: [String: Any] = [:]
        if let inherited, !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: Data(inherited.utf8))
            } catch {
                throw LinkCError.process("\(source) is not JSON, so linkC cannot add its tools to it — \(error.localizedDescription)")
            }
            guard let object = parsed as? [String: Any] else {
                throw LinkCError.process("\(source) is not a JSON object, so linkC cannot add its tools to it")
            }
            root = object
        }
        var mcp = try mcpTable(in: root, of: source)
        mcp[serverName] = entry
        root["mcp"] = mcp
        if let model {
            root["model"] = model
            var agentTable = try table(root["agent"], key: "agent", of: source)
            for name in agents {
                var settings = try table(agentTable[name], key: "agent.\(name)", of: source)
                settings["model"] = model
                agentTable[name] = settings
            }
            root["agent"] = agentTable
        }
        if let smallModel { root["small_model"] = smallModel }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    public static func registerTomlServer(
        configFile: URL,
        serverName: String = MCPRegistrar.serverName,
        binaryPath: String,
        args: [String] = [],
        env: [String: String] = [:]
    ) throws {
        var content = try readText(at: configFile)

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

        try writeAtomically(Data(content.utf8), to: configFile)
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
        binaryPath: String = defaultBinaryPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment
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
        // OpenCode: ~/.config/opencode/opencode.json, in its own `mcp` shape
        if let f = attemptRegistration("~/.config/opencode/opencode.json", {
            try registerOpenCodeServer(configFile: openCodeConfigFile(home: home), binaryPath: binaryPath)
        }) { failures.append(f) }
        // Freebuff: ~/.agents/mcp.json, in the shared `mcpServers` shape.
        if let f = attemptRegistration("~/.agents/mcp.json", {
            try registerFreebuffServer(configFile: freebuffConfigFile(home: home), binaryPath: binaryPath)
        }) { failures.append(f) }

        // Kilo: ~/.config/kilo/kilo.jsonc (or kilo.json when that is the file present), OpenCode's `mcp` shape
        let kiloFile = kiloConfigFile(home: home)
        if let f = attemptRegistration("~/.config/kilo/\(kiloFile.lastPathComponent)", {
            try registerKiloServer(configFile: kiloFile, binaryPath: binaryPath)
        }) { failures.append(f) }

        // Crush: crush.json in its config folder (~/.config/crush by default), in its own `mcp` shape
        let crushFile = crushConfigFile(home: home, environment: environment)
        if let f = attemptRegistration("crush.json (\(crushFile.path))", {
            try registerCrushServer(configFile: crushFile, binaryPath: binaryPath)
        }) { failures.append(f) }

        guard failures.isEmpty else {
            throw LinkCError.server("failed to register with: \(failures.joined(separator: "; "))")
        }
    }
}
