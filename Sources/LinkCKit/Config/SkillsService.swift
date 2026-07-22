import Foundation
import Observation

/// The unified skills catalog for the panel, with the one light-management action: plugin
/// enable/disable — always through the `claude` CLI, never by editing claude's files, and
/// always followed by a re-read of authoritative state (no optimistic flips).
@MainActor
@Observable
public final class SkillsService {
    public private(set) var skills: [SkillEntry] = []
    public private(set) var plugins: [InstalledPlugin] = []
    public private(set) var isLoading = false
    /// The plugin id with a toggle in flight — its switch disables until the CLI settles.
    public private(set) var togglingPluginId: String?
    public private(set) var lastError: String?

    private let claudePath: String
    private let configURL: URL
    private let discovery: SkillDiscovery
    private let runner: any ProcessRunner
    private static let cliTimeout: TimeInterval = 15

    public init(
        claudePath: String,
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        discovery: SkillDiscovery = SkillDiscovery(),
        runner: any ProcessRunner = LiveProcessRunner()
    ) {
        self.claudePath = claudePath
        self.configURL = configURL
        self.discovery = discovery
        self.runner = runner
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let listOutput = try await runner.run(
                claudePath, args: ["plugin", "list", "--json"], cwd: nil, timeout: Self.cliTimeout
            )
            let installed = try PluginList.parse(Data(listOutput.utf8))
            // Usage stats are decoration — a missing/unreadable config just means zero counts.
            let usage = (try? ClaudeUserConfig.parse(Data(contentsOf: configURL)))?.skillUsage ?? [:]

            let pluginSkills = installed.flatMap { plugin in
                discovery.pluginSkills(installPath: plugin.installPath)
                    .map { (plugin: plugin, path: $0.path, frontmatter: $0.frontmatter) }
            }
            skills = SkillCatalog.merge(
                userSkills: discovery.userSkills(),
                pluginSkills: pluginSkills,
                usage: usage
            )
            plugins = installed
            lastError = nil
        } catch {
            lastError = "Couldn't load skills: \(error.localizedDescription)"
        }
    }

    public func setPluginEnabled(_ plugin: InstalledPlugin, enabled: Bool) async throws {
        togglingPluginId = plugin.id
        defer { togglingPluginId = nil }
        do {
            _ = try await runner.run(
                claudePath,
                args: ["plugin", enabled ? "enable" : "disable", plugin.id, "--scope", plugin.scope],
                cwd: nil,
                timeout: Self.cliTimeout
            )
        } catch {
            lastError = "Couldn't \(enabled ? "enable" : "disable") \(plugin.id): "
                + "\(error.localizedDescription). It may need `claude plugin \(enabled ? "enable" : "disable") \(plugin.id)` run manually."
            throw error
        }
        await refresh()
    }
}
