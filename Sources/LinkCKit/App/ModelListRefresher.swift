import Foundation
import Observation

/// Refreshes each agent's live model list into `ModelListCache`.
/// Runs at start, every 6 hours, and when Settings asks (`refreshNow()`).
///
/// What Settings shows is `lists`, `isRefreshing` and the cache problems below: all observable, so
/// a view reads them and redraws when a refresh ends, and never reads the file itself.
@MainActor
@Observable
public final class ModelListRefresher {
    public static let defaultInterval: Duration = .seconds(21_600)

    public typealias Runner = @Sendable (AgentKind) async throws -> String
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Each agent's list as of the last refresh, or as the cache held it when the app started.
    public private(set) var lists: [AgentKind: AgentModelList] = [:]
    /// True while a refresh runs.
    public private(set) var isRefreshing = false
    /// Why the cache file could not be read, or nil when the last read worked. An unreadable file is
    /// moved aside (`.corrupt`) before the next write, so nothing in it is lost silently.
    public private(set) var cacheReadError: String?
    /// Why the cache file could not be written, or nil when the last write worked. The lists stay
    /// in memory, so Settings still shows what was fetched.
    public private(set) var cacheWriteError: String?

    /// What went wrong with the cache file, for Settings to show; nil when it is fine.
    public var cacheProblem: String? {
        [cacheReadError, cacheWriteError].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    @ObservationIgnored private let cache: ModelListCache
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let sleep: Sleeper
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    /// Agents whose models come from a CLI listing.
    public static var listedAgents: [AgentKind] { ModelListParser.listedAgents }

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
        if let read = readCache() { lists = read }
    }

    /// Starts the loop: refresh once, then sleep `interval` and repeat. Cancelling stops it.
    public func start() async {
        loopTask?.cancel()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                do {
                    try await self.sleep(self.interval)
                } catch is CancellationError {
                    return
                } catch {
                    NSLog("[linkC models] the refresh schedule's sleep failed — %@; refreshing again", String(describing: error))
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

    /// Lists every CLI agent now and writes the cache. A failure keeps the last models and sets
    /// `error`. A refresh already running is not started again.
    public func refreshNow() async {
        guard !isRefreshing else {
            NSLog("[linkC models] a refresh is already running; not starting another")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let cacheWasUnreadable: String?
        var working = lists
        if let read = readCache() {
            working = read
            cacheWasUnreadable = nil
        } else {
            cacheWasUnreadable = cacheReadError
            quarantineUnreadableCache()
        }

        let stamped = now()
        // One `cursor-agent models` run serves Cursor and Grok.
        var cursorRun: Result<String, Error>?
        for agent in ModelListParser.listedAgents {
            do {
                let output: String
                if agent == .cursor || agent == .grok {
                    if cursorRun == nil {
                        do { cursorRun = .success(try await runner(.cursor)) } catch { cursorRun = .failure(error) }
                    }
                    output = try cursorRun!.get()
                } else {
                    output = try await runner(agent)
                }
                let models = try ModelListParser.listing(output, for: agent)
                working[agent] = AgentModelList(models: models, fetchedAt: stamped, error: nil)
            } catch is CancellationError {
                // The refresh was cancelled (the app is quitting): what was listed so far is kept.
                break
            } catch {
                var message = String(describing: error)
                if let cacheWasUnreadable { message += " (the model list cache was unreadable: \(cacheWasUnreadable))" }
                NSLog("[linkC models] listing %@ failed — %@", agent.rawValue, message)
                let previous = working[agent]
                working[agent] = AgentModelList(
                    models: previous?.models ?? [], fetchedAt: previous?.fetchedAt, error: message)
            }
        }
        lists = working
        do {
            try cache.write(working)
            cacheWriteError = nil
        } catch {
            NSLog("[linkC models] could not write %@ — %@", cache.url.path, String(describing: error))
            cacheWriteError = "The model list cache \(cache.url.lastPathComponent) could not be written: \(error)"
        }
    }

    /// The cache's lists, or nil when the file cannot be read (recorded in `cacheReadError`). A missing
    /// file is an empty cache, not an error.
    private func readCache() -> [AgentKind: AgentModelList]? {
        do {
            let read = try cache.read()
            cacheReadError = nil
            return read
        } catch {
            NSLog("[linkC models] could not read %@ — %@", cache.url.path, String(describing: error))
            cacheReadError = "The model list cache \(cache.url.lastPathComponent) is unreadable: \(error)"
            return nil
        }
    }

    private func quarantineUnreadableCache() {
        do {
            let moved = try cache.moveUnreadableAside()
            NSLog("[linkC models] the unreadable cache was moved to %@", moved.path)
        } catch {
            NSLog("[linkC models] could not move %@ aside — %@", cache.url.path, String(describing: error))
            cacheReadError = (cacheReadError ?? "") + " It could not be moved aside: \(error)"
        }
    }

    /// Production runner: `agy models`, `cursor-agent models`, `opencode models --standalone`,
    /// `kilo models`. Grok reuses Cursor's listing. Claude and Codex have fixed lists and are not run.
    public nonisolated static func liveRunner(_ agent: AgentKind) async throws -> String {
        try await ModelListCommands.run(for: agent)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The CLI commands that list models, run through the app's process runner: off the main actor and
/// off the cooperative thread pool, with a timeout, failing with the CLI's own stderr.
enum ModelListCommands {
    static func run(for agent: AgentKind) async throws -> String {
        switch agent {
        case .agy:
            return try await capture(agent: .agy, args: ["models"])
        case .cursor, .grok:
            return try await captureCursorModels()
        case .opencode:
            return try await capture(agent: .opencode, args: MCPServer.openCodeModelsArguments)
        case .kilo:
            return try await capture(agent: .kilo, args: MCPServer.kiloModelsArguments)
        case .claude, .codex, .shell:
            throw LinkCError.process("\(agent.rawValue) has no model listing command")
        }
    }

    private static func capture(agent: AgentKind, args: [String]) async throws -> String {
        guard let executable = AgentDescriptor.resolveExecutable(for: agent) else {
            throw LinkCError.process("Executable for \(agent.pillText) not found")
        }
        return try await LiveProcessRunner().run(
            executable, args: args, cwd: nil,
            env: AgentDescriptor.environment(for: agent, home: FileManager.default.homeDirectoryForCurrentUser),
            timeout: 60)
    }

    /// Prefers a `cursor-agent` binary beside `cursor`, otherwise `cursor agent models`.
    private static func captureCursorModels() async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = [
            home.appendingPathComponent(".local/bin/cursor-agent").path,
            "/usr/local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
        ]
        let cursor = AgentDescriptor.resolveExecutable(for: .cursor)
        if let cursor {
            candidates.insert((cursor as NSString).deletingLastPathComponent + "/cursor-agent", at: 0)
        }
        let fm = FileManager.default
        if let agentBin = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return try await LiveProcessRunner().run(agentBin, args: ["models"], cwd: nil, env: [:], timeout: 60)
        }
        guard let cursor else {
            throw LinkCError.process("Executable for \(AgentKind.cursor.pillText) not found")
        }
        return try await LiveProcessRunner().run(cursor, args: ["agent", "models"], cwd: nil, env: [:], timeout: 60)
    }
}
