import Foundation
import Observation

/// Live MCP state for the panel: configured servers (from `~/.claude.json`, read-only) plus
/// per-server health from `claude mcp list`. Config loads synchronously so the screen renders
/// instantly; health arrives async. Errors surface in `lastError` — never swallowed.
@MainActor
@Observable
public final class MCPServerService {
    public private(set) var servers: [MCPServerConfig] = []
    public private(set) var projectServers: [MCPServerConfig] = []
    /// Live status keyed by server name — covers global servers and claude.ai connectors.
    public private(set) var health: [String: MCPHealthStatus] = [:]
    /// claude.ai managed connectors (Gmail/Drive/Calendar) — reported by `claude mcp list`
    /// but absent from the config file entirely.
    public private(set) var connectedAccounts: [MCPHealthStatus] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?

    private let claudePath: String
    private let configURL: URL
    private let runner: any ProcessRunner
    private static let healthTimeout: TimeInterval = 15

    public init(
        claudePath: String,
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        runner: any ProcessRunner = LiveProcessRunner()
    ) {
        self.claudePath = claudePath
        self.configURL = configURL
        self.runner = runner
    }

    public func loadConfig() {
        do {
            let config = try ClaudeUserConfig.parse(Data(contentsOf: configURL))
            servers = config.mcpServers
            projectServers = config.projectMCPServers
            lastError = nil
        } catch {
            servers = []
            projectServers = []
            lastError = "Couldn't read \(configURL.path): \(error.localizedDescription)"
        }
    }

    public func refreshHealth() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await runner.run(
                claudePath, args: ["mcp", "list"],
                cwd: FileManager.default.homeDirectoryForCurrentUser,
                timeout: Self.healthTimeout
            )
            let statuses = MCPHealthCheck.parse(output)
            let configuredNames = Set(servers.map(\.name))
            health = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
            connectedAccounts = statuses.filter { !configuredNames.contains($0.name) }
            lastError = nil
        } catch {
            lastError = "MCP health check failed: \(error.localizedDescription)"
        }
    }
}
