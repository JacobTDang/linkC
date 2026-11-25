import Foundation

/// An agent-browser MCP server as the user registered it in one agent's own config.
public struct AgentBrowserServer: Equatable, Sendable {
    /// The server's key in the config.
    public let name: String
    /// The server's command followed by its arguments.
    public let commandLine: [String]
    /// The whole entry as JSON text, for an inline config that would otherwise replace it with a
    /// partial one (OpenCode, Kilo). Nil for configs that are not JSON.
    public let entryJSON: String?

    public init(name: String, commandLine: [String], entryJSON: String? = nil) {
        self.name = name
        self.commandLine = commandLine
        self.entryJSON = entryJSON
    }

    /// The command line that runs agent-browser's own CLI: the server's, up to the word that names
    /// agent-browser (`npx -y agent-browser mcp` gives `npx -y agent-browser`).
    public var cliPrefix: [String] {
        guard let index = commandLine.firstIndex(where: Self.namesAgentBrowser) else { return ["agent-browser"] }
        return Array(commandLine[...index])
    }

    /// A word of a command line that runs agent-browser: its last path component starts with the
    /// name, so a full path, `agent-browser@latest` and `@scope/agent-browser` all count.
    static func namesAgentBrowser(_ word: String) -> Bool {
        (word as NSString).lastPathComponent.hasPrefix("agent-browser")
    }
}

extension MCPRegistrar {
    /// The agent-browser server `agent` would start in `cwd`, read from that agent's own config. Nil
    /// when none is registered, or when it is disabled. Throws, naming the file, when a config that
    /// exists cannot be read, or when the server cannot be passed the browser (a Codex name that
    /// needs quotes), so the caller can say why the session got no browser.
    public static func agentBrowserServer(
        for agent: AgentKind, cwd: String, home: URL, environment: [String: String]
    ) throws -> AgentBrowserServer? {
        switch agent {
        case .codex:
            let file = home.appendingPathComponent(".codex/config.toml")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try codexAgentBrowserServer(in: try readText(at: file), file: file.path)
        case .opencode:
            return try jsonServer(in: openCodeConfigFile(home: home), table: "mcp")
        case .kilo:
            return try jsonServer(in: kiloConfigFile(home: home), table: "mcp")
        case .crush:
            return try jsonServer(in: crushConfigFile(home: home, environment: environment), table: "mcp")
        case .agy:
            let folder = home.appendingPathComponent(".gemini", isDirectory: true)
            return try jsonServer(in: folder.appendingPathComponent("config/mcp_config.json"), table: "mcpServers")
                ?? jsonServer(in: folder.appendingPathComponent("antigravity-cli/mcp.json"), table: "mcpServers")
        case .claude:
            return try claudeAgentBrowserServer(cwd: cwd, home: home)
        case .cursor, .grok, .freebuff, .shell:
            // Their MCP servers start with a fixed handful of variables, so nothing linkC puts in
            // the terminal reaches them.
            return nil
        }
    }

    /// Claude's user servers, then the servers of `cwd`'s own project entry in `~/.claude.json`,
    /// then the project's `.mcp.json`.
    private static func claudeAgentBrowserServer(cwd: String, home: URL) throws -> AgentBrowserServer? {
        let file = home.appendingPathComponent(".claude.json")
        if let root = try readJSONC(at: file) {
            if let found = try server(in: root["mcpServers"], file: file.path) { return found }
            if let projects = root["projects"] as? [String: Any] {
                for key in Set([cwd, ProjectPath.canonical(cwd)]).sorted() {
                    guard let project = projects[key] as? [String: Any] else { continue }
                    if let found = try server(in: project["mcpServers"], file: file.path) { return found }
                }
            }
        }
        return try jsonServer(in: URL(fileURLWithPath: cwd).appendingPathComponent(".mcp.json"), table: "mcpServers")
    }

    /// The first enabled server under `table` in the JSON(C) file whose command runs agent-browser.
    private static func jsonServer(in file: URL, table: String) throws -> AgentBrowserServer? {
        guard let root = try readJSONC(at: file) else { return nil }
        return try server(in: root[table], file: file.path)
    }

    private static func server(in table: Any?, file: String) throws -> AgentBrowserServer? {
        guard let servers = table as? [String: Any] else { return nil }
        for name in servers.keys.sorted() {
            guard let entry = servers[name] as? [String: Any], entry["enabled"] as? Bool != false else { continue }
            var commandLine: [String] = []
            if let command = entry["command"] as? String { commandLine.append(command) }
            if let command = entry["command"] as? [String] { commandLine += command }
            if let args = entry["args"] as? [String] { commandLine += args }
            guard commandLine.contains(where: AgentBrowserServer.namesAgentBrowser) else { continue }
            let json = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
            return AgentBrowserServer(name: name, commandLine: commandLine, entryJSON: String(decoding: json, as: UTF8.self))
        }
        return nil
    }

    /// The JSON object in `file` once comments and trailing commas are gone; nil when there is no
    /// such file. Throws, naming the file, when it is not a JSON object even then.
    static func readJSONC(at file: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let text = try readText(at: file)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(strippingJSONC(text).utf8))
        } catch {
            throw LinkCError.server("\(file.path) is not JSON linkC can read — \(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw LinkCError.server("\(file.path) does not hold a JSON object")
        }
        return object
    }

    /// `text` without `//` and `/* */` comments and without a comma before a closing bracket, both
    /// only outside strings.
    static func strippingJSONC(_ text: String) -> String {
        var out: [Character] = []
        var chars = Array(text)[...]
        var inString = false
        while let c = chars.popFirst() {
            if inString {
                out.append(c)
                if c == "\\", let escaped = chars.popFirst() { out.append(escaped) } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "/" where chars.first == "/":
                while let next = chars.first, next != "\n" { chars.removeFirst() }
            case "/" where chars.first == "*":
                chars.removeFirst()
                while let next = chars.popFirst() {
                    if next == "*", chars.first == "/" { chars.removeFirst(); break }
                }
                out.append(" ")
            case "}", "]":
                if let comma = out.lastIndex(where: { !$0.isWhitespace }), out[comma] == "," { out.remove(at: comma) }
                out.append(c)
            default:
                out.append(c)
            }
        }
        return String(out)
    }

    // MARK: - Codex's TOML

    /// The first `[mcp_servers.<name>]` table whose `command` or `args` runs agent-browser. Only a
    /// server's own header counts — never a sub-table such as `[mcp_servers.<name>.env]` — and
    /// comments are ignored. A name that needs quotes throws: Codex's `-c` override splits on dots
    /// and would make a second server of it.
    static func codexAgentBrowserServer(in text: String, file: String) throws -> AgentBrowserServer? {
        for table in codexTables(in: text) {
            guard table.path.count == 2, table.path[0].key == "mcp_servers" else { continue }
            let body = table.body.joined(separator: "\n")
            guard codexValue("enabled", in: body) != "false" else { continue }
            let command = codexValue("command", in: body).map(codexStrings) ?? []
            let args = codexValue("args", in: body).map(codexStrings) ?? []
            let commandLine = command + args
            guard commandLine.contains(where: AgentBrowserServer.namesAgentBrowser) else { continue }
            let name = table.path[1].key
            guard isBareKey(name) else {
                throw LinkCError.process(
                    "Codex's agent-browser server in \(file) is named \"\(name)\", which needs quotes; linkC can pass the browser only to a server named with letters, digits, - and _. Rename it, for example to [mcp_servers.agent-browser]")
            }
            return AgentBrowserServer(name: name, commandLine: commandLine)
        }
        return nil
    }

    private struct TomlKey { let key: String; let quoted: Bool }
    private struct TomlTable { let path: [TomlKey]; var body: [String] }

    /// Each `[table]` header in `text`, with the comment-free lines that follow it. Array-of-table
    /// headers (`[[…]]`) end a table but are not one.
    private static func codexTables(in text: String) -> [TomlTable] {
        var tables: [TomlTable] = []
        var current: TomlTable?
        for raw in text.components(separatedBy: .newlines) {
            let line = withoutTomlComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { tables.append(current) }
                current = nil
                guard !line.hasPrefix("[["), line.hasSuffix("]"),
                      let path = tomlKeyPath(String(line.dropFirst().dropLast())) else { continue }
                current = TomlTable(path: path, body: [])
            } else {
                current?.body.append(line)
            }
        }
        if let current { tables.append(current) }
        return tables
    }

    /// `line` up to a `#` that is not inside a string.
    private static func withoutTomlComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (offset, c) in line.enumerated() {
            if let open = quote {
                if escaped { escaped = false } else if c == "\\" && open == "\"" { escaped = true } else if c == open { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    /// The dotted key of a table header, each part bare or quoted; nil when it is not one.
    private static func tomlKeyPath(_ header: String) -> [TomlKey]? {
        var keys: [TomlKey] = []
        var rest = header.trimmingCharacters(in: .whitespaces)[...]
        while !rest.isEmpty {
            if let quote = rest.first, quote == "\"" || quote == "'" {
                rest.removeFirst()
                guard let close = rest.firstIndex(of: quote) else { return nil }
                keys.append(TomlKey(key: String(rest[..<close]), quoted: true))
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.firstIndex(of: ".") ?? rest.endIndex
                let key = rest[..<end].trimmingCharacters(in: .whitespaces)
                guard isBareKey(key) else { return nil }
                keys.append(TomlKey(key: key, quoted: false))
                rest = rest[end...]
            }
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.first == "." { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) } else if !rest.isEmpty { return nil }
        }
        return keys.isEmpty ? nil : keys
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// The text after `key =` in a table body, through the closing `]` when it is an array.
    private static func codexValue(_ key: String, in body: String) -> String? {
        let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*(\\[[^\\]]*\\]|[^\\n]*)"
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return body[range].trimmingCharacters(in: .whitespaces)
    }

    /// The strings in a TOML string or string-array value.
    private static func codexStrings(_ value: String) -> [String] {
        let pattern = #""((?:\\.|[^"\\])*)"|'([^']*)'"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            return Range(match.range(at: group), in: value).map { String(value[$0]) }
        }
    }
}
