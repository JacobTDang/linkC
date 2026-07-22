import Foundation

/// One configured MCP server, with secrets structurally removed: header and env VALUES are
/// discarded at parse time — only key names survive — so no view, log, or clipboard path can
/// ever leak them.
public struct MCPServerConfig: Equatable, Sendable, Identifiable {
    public enum Transport: Equatable, Sendable {
        case http(url: String, headerKeys: [String])
        case stdio(command: String, args: [String], envKeys: [String])
    }

    public enum Scope: Equatable, Sendable {
        case global
        case project(path: String)
    }

    public let name: String
    public let scope: Scope
    public let transport: Transport
    /// True when the owning project lists this name in `disabledMcpjsonServers`.
    public let isDisabledForProject: Bool

    public var id: String {
        switch scope {
        case .global: return "global/\(name)"
        case .project(let path): return "\(path)/\(name)"
        }
    }
}

/// The one decoder for `~/.claude.json` — a large, frequently rewritten file we read
/// selectively (Decodable ignores the dozens of keys we don't declare) and NEVER write.
public struct ClaudeUserConfig: Sendable {
    public struct UsageStat: Equatable, Sendable {
        public let usageCount: Int
        public let lastUsedAt: Date?
    }

    public let mcpServers: [MCPServerConfig]         // global scope, sorted by name
    public let projectMCPServers: [MCPServerConfig]  // project scope, sorted by path then name
    public let skillUsage: [String: UsageStat]       // key: "name" or "plugin:skill"
    public let pluginUsage: [String: UsageStat]      // key: "plugin@marketplace"

    public static func parse(_ data: Data) throws -> ClaudeUserConfig {
        let raw = try JSONDecoder().decode(RawConfig.self, from: data)

        let global = (raw.mcpServers ?? [:])
            .compactMap { name, server in server.config(name: name, scope: .global, disabled: false) }
            .sorted { $0.name < $1.name }

        let project = (raw.projects ?? [:])
            .flatMap { path, projectConfig -> [MCPServerConfig] in
                let disabled = Set(projectConfig.disabledMcpjsonServers ?? [])
                return (projectConfig.mcpServers ?? [:]).compactMap { name, server in
                    server.config(name: name, scope: .project(path: path), disabled: disabled.contains(name))
                }
            }
            .sorted { ($0.id, $0.name) < ($1.id, $1.name) }

        return ClaudeUserConfig(
            mcpServers: global,
            projectMCPServers: project,
            skillUsage: (raw.skillUsage ?? [:]).mapValues(\.stat),
            pluginUsage: (raw.pluginUsage ?? [:]).mapValues(\.stat)
        )
    }

    // MARK: - Raw shapes

    private struct RawConfig: Decodable {
        let mcpServers: [String: RawServer]?
        let projects: [String: RawProject]?
        let skillUsage: [String: RawUsage]?
        let pluginUsage: [String: RawUsage]?
    }

    private struct RawProject: Decodable {
        let mcpServers: [String: RawServer]?
        let disabledMcpjsonServers: [String]?
    }

    private struct RawServer: Decodable {
        let type: String?
        let url: String?
        let headers: [String: String]?
        let command: String?
        let args: [String]?
        let env: [String: String]?

        /// Secret values die here: only header/env KEY NAMES cross into the model.
        func config(name: String, scope: MCPServerConfig.Scope, disabled: Bool) -> MCPServerConfig? {
            let transport: MCPServerConfig.Transport
            switch type {
            case "http", "sse":
                guard let url else { return nil }
                transport = .http(url: url, headerKeys: (headers ?? [:]).keys.sorted())
            case "stdio", nil:  // stdio is claude's default when type is omitted
                guard let command else { return nil }
                transport = .stdio(command: command, args: args ?? [], envKeys: (env ?? [:]).keys.sorted())
            default:
                return nil
            }
            return MCPServerConfig(name: name, scope: scope, transport: transport, isDisabledForProject: disabled)
        }
    }

    private struct RawUsage: Decodable {
        let usageCount: Int?
        let lastUsedAt: Double?

        var stat: UsageStat {
            UsageStat(
                usageCount: usageCount ?? 0,
                lastUsedAt: lastUsedAt.map { Date(timeIntervalSince1970: $0 / 1000) }  // ms epoch
            )
        }
    }
}
