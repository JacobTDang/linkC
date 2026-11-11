import Foundation

/// Refreshes each agent's live model list into `ModelListCache`.
/// Runs at start, every 6 hours, and when Settings asks (`refreshNow()`).
@MainActor
public final class ModelListRefresher {
    public static let defaultInterval: Duration = .seconds(21_600)

    public typealias Runner = @Sendable (AgentKind) async throws -> String
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let cache: ModelListCache
    private let runner: Runner
    private let sleep: Sleeper
    private let interval: Duration
    private let now: @Sendable () -> Date
    private var loopTask: Task<Void, Never>?

    /// Agents whose models come from a CLI listing.
    public static let listedAgents: [AgentKind] = [.agy, .cursor, .grok, .opencode]

    public init(
        cache: ModelListCache = .applicationSupport,
        runner: @escaping Runner = ModelListRefresher.liveRunner,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        interval: Duration = ModelListRefresher.defaultInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cache = cache
        self.runner = runner
        self.sleep = sleep
        self.interval = interval
        self.now = now
    }

    /// Starts the loop: refresh once, then sleep `interval` and repeat. Cancelling stops it.
    public func start() async {
        loopTask?.cancel()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                do {
                    try await self?.sleep(self?.interval ?? ModelListRefresher.defaultInterval)
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
        loopTask = task
        await task.value
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Lists every CLI agent now and writes the cache. A failure keeps the last models and sets `error`.
    public func refreshNow() async {
        var lists = (try? cache.read()) ?? [:]
        let stamped = now()
        for agent in Self.listedAgents {
            do {
                let output = try await runner(agent)
                let models: [ListedModel]
                switch agent {
                case .agy: models = ModelListParser.agy(output)
                case .cursor: models = ModelListParser.cursor(output)
                case .grok: models = ModelListParser.grok(fromCursor: output)
                case .opencode: models = ModelListParser.openCode(output)
                case .claude, .codex, .shell: models = []
                }
                lists[agent] = AgentModelList(models: models, fetchedAt: stamped, error: nil)
            } catch {
                let previous = lists[agent]
                lists[agent] = AgentModelList(
                    models: previous?.models ?? [],
                    fetchedAt: previous?.fetchedAt,
                    error: String(describing: error))
            }
        }
        try? cache.write(lists)
    }

    /// Production runner: `agy models`, `cursor-agent models`, `opencode models --standalone`.
    /// Grok reuses Cursor's listing. Claude and Codex have fixed lists and are not run.
    public nonisolated static func liveRunner(_ agent: AgentKind) async throws -> String {
        try await Task.detached {
            try ModelListCommands.run(for: agent)
        }.value
    }
}

/// Process-level model listing commands. Kept off the main actor so `Task.detached` can call them.
enum ModelListCommands {
    static func run(for agent: AgentKind) throws -> String {
        switch agent {
        case .agy:
            return try capture(agent: .agy, args: ["models"])
        case .cursor, .grok:
            return try captureCursorModels()
        case .opencode:
            return try capture(agent: .opencode, args: MCPServer.openCodeModelsArguments)
        case .claude, .codex, .shell:
            return ""
        }
    }

    private static func capture(agent: AgentKind, args: [String]) throws -> String {
        guard let executable = AgentDescriptor.resolveExecutable(for: agent) else {
            throw LinkCError.process("Executable for \(agent.pillText) not found")
        }
        let result = try LiveProcessRunner.runCapturingSync(
            executable: executable, args: args, cwd: nil,
            env: AgentDescriptor.environment(for: agent, home: FileManager.default.homeDirectoryForCurrentUser),
            timeout: 60)
        guard result.status == 0 else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinkCError.process("`\(agent.rawValue) \(args.joined(separator: " "))` exited \(result.status): \(err)")
        }
        return result.stdout
    }

    /// Prefers a `cursor-agent` binary beside `cursor`, otherwise `cursor agent models`.
    private static func captureCursorModels() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = [
            home.appendingPathComponent(".local/bin/cursor-agent").path,
            "/usr/local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
        ]
        if let cursor = AgentDescriptor.resolveExecutable(for: .cursor) {
            let sibling = (cursor as NSString).deletingLastPathComponent + "/cursor-agent"
            candidates.insert(sibling, at: 0)
            candidates.append(cursor)
        }
        let fm = FileManager.default
        if let agentBin = candidates.first(where: {
            ($0 as NSString).lastPathComponent == "cursor-agent" && fm.isExecutableFile(atPath: $0)
        }) {
            let result = try LiveProcessRunner.runCapturingSync(
                executable: agentBin, args: ["models"], cwd: nil, env: [:], timeout: 60)
            guard result.status == 0 else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LinkCError.process("`cursor-agent models` exited \(result.status): \(err)")
            }
            return result.stdout
        }
        guard let cursor = AgentDescriptor.resolveExecutable(for: .cursor) else {
            throw LinkCError.process("Executable for \(AgentKind.cursor.pillText) not found")
        }
        let result = try LiveProcessRunner.runCapturingSync(
            executable: cursor, args: ["agent", "models"], cwd: nil, env: [:], timeout: 60)
        guard result.status == 0 else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinkCError.process("`cursor agent models` exited \(result.status): \(err)")
        }
        return result.stdout
    }
}
