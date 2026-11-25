import Foundation
import Observation

/// Live usage state for the panel, composed from the pure pieces: per-session context fill
/// and token/dollar totals (from each session's own transcript), and the global plan-window
/// figures (from a sweep of every recent transcript under `~/.claude/projects`). Fed by hook
/// events; a timer while the panel is visible keeps it fresh between events.
@MainActor
@Observable
public final class UsageTracker {
    public struct SessionUsage: Equatable, Sendable {
        /// The last main-chain message's context size — how full this conversation is.
        public let contextTokens: Int
        public let totalTokens: Int
        /// Approximate dollars; excludes messages from models missing in the pricing table.
        public let cost: Double
        public let hasUnpricedTokens: Bool
        /// 0…1 against the model's window (200k, or 1M for "[1m]" models), for the hairline.
        public let contextFill: Double
    }

    public private(set) var window: WindowUsage?

    private let projectsDir: URL
    private let sessionReader = TranscriptTailReader()
    private let scanReader = TranscriptTailReader()
    private var sessionPaths: [String: String] = [:]
    private var accumulators: [String: Accumulator] = [:]
    private var agentAssemblers: [String: AgentAssembler] = [:]
    private var activities: [String: CurrentActivity] = [:]
    private var titles: [String: String] = [:]
    /// Each session's running subagents' own transcripts, by the spawning tool_use id.
    private var subagentFiles: [String: [String: String]] = [:]
    /// The step each running subagent's own transcript is on, by the spawning tool_use id.
    private var subagentActivities: [String: [String: CurrentActivity]] = [:]
    /// One reader per session, so unbinding a session drops its subagents' offsets too.
    private var subagentReaders: [String: TranscriptTailReader] = [:]
    /// What each session's `subagents` folder was last found to hold.
    private var subagentFolders: [String: SubagentFolder] = [:]
    /// Meta files and folders already said to be unreadable, so each is said once.
    private var unreadableMeta: Set<String> = []
    private var scanRecords: [MessageUsage] = []

    /// First-scan cost bound: only the trailing 4MB of a historical transcript is read, and
    /// only files touched in the last 7 days are scanned at all. The footer is approximate
    /// by design (see spec) — this keeps the first sweep from chewing through gigabytes.
    private static let firstScanTailCap = 4 * 1024 * 1024
    private static let scanWindow: TimeInterval = 7 * 24 * 3600

    public init(
        projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    ) {
        self.projectsDir = projectsDir
    }

    // MARK: - Per session

    public func bind(sessionId: String, transcriptPath: String) {
        sessionPaths[sessionId] = transcriptPath
    }

    public func refreshSession(_ sessionId: String) {
        guard let path = sessionPaths[sessionId] else { return }
        var acc = accumulators[sessionId] ?? Accumulator()
        var agents = agentAssemblers[sessionId] ?? AgentAssembler()
        var activity = activities[sessionId]
        var title = titles[sessionId]
        for line in sessionReader.readNewLines(at: path) {
            if let usage = TranscriptUsage.parseLine(line) {
                acc.add(usage)
            }
            if let named = ClaudeTitle.parse(line) {
                title = named
            }
            // One decode feeds both event consumers (TranscriptUsage keeps its own
            // pricing-critical parser — see TranscriptLine's doc comment).
            if let decoded = TranscriptLine.decode(line) {
                let events = AgentEvents.events(from: decoded)
                if !events.isEmpty { agents.feed(events) }
                activity = ActivityEvents.apply(decoded, to: activity)
            }
        }
        if accumulators[sessionId] != acc { accumulators[sessionId] = acc }
        if agentAssemblers[sessionId] != agents { agentAssemblers[sessionId] = agents }
        refreshSubagents(sessionId, transcriptPath: path, running: agents.runs.filter(\.isRunning).map(\.id))
        if activities[sessionId] != activity { activities[sessionId] = activity }
        if titles[sessionId] != title { titles[sessionId] = title }
    }

    /// Follows each running subagent's own transcript, `<session>/subagents/agent-<id>.jsonl`, found
    /// by the `agent-<id>.meta.json` beside it that names the spawning tool_use.
    private func refreshSubagents(_ sessionId: String, transcriptPath: String, running: [String]) {
        var files = (subagentFiles[sessionId] ?? [:]).filter { running.contains($0.key) }
        var steps = (subagentActivities[sessionId] ?? [:]).filter { running.contains($0.key) }
        let folder = ((transcriptPath as NSString).deletingPathExtension as NSString).appendingPathComponent("subagents")
        if running.contains(where: { files[$0] == nil }) {
            var known = subagentFolders[sessionId] ?? SubagentFolder()
            scanSubagentFolder(folder, into: &known)
            subagentFolders[sessionId] = known
            for (name, toolUseId) in known.toolUseIds {
                guard let toolUseId, running.contains(toolUseId) else { continue }
                files[toolUseId] = (folder as NSString).appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
            }
        }
        let reader = subagentReaders[sessionId] ?? TranscriptTailReader()
        subagentReaders[sessionId] = reader
        for (toolUseId, file) in files {
            var step = steps[toolUseId]
            for line in reader.readNewLines(at: file) {
                if let decoded = TranscriptLine.decode(line) {
                    step = ActivityEvents.apply(decoded, to: step, includingSidechain: true)
                }
            }
            steps[toolUseId] = step
        }
        if subagentFiles[sessionId] != files { subagentFiles[sessionId] = files }
        if subagentActivities[sessionId] != steps { subagentActivities[sessionId] = steps }
    }

    private struct SubagentMeta: Decodable {
        let toolUseId: String?
    }

    /// A session's `subagents` folder as last read: a folder can hold hundreds of meta files, and
    /// every hook event looks for a running subagent's while it has none.
    private struct SubagentFolder {
        /// The folder's modification time when it was last listed; it moves when a file is added.
        var listedAt: Date?
        /// The tool_use each meta file names, by file name; nil for one that names none. A meta file
        /// names its spawn when it is made, so each is decoded once.
        var toolUseIds: [String: String?] = [:]
        /// Meta files that could not be decoded, perhaps caught half written: decoded again each time.
        var unreadable: Set<String> = []
    }

    /// Lists the folder when its modification time has moved since the last listing, then decodes the
    /// meta files not decoded yet. A meta file that cannot be read is said once.
    private func scanSubagentFolder(_ folder: String, into known: inout SubagentFolder) {
        do {
            // Before the listing: a file added after it moves the time again.
            let modified = try FileManager.default.attributesOfItem(atPath: folder)[.modificationDate] as? Date
            if modified == nil || modified != known.listedAt {
                let names = try FileManager.default.contentsOfDirectory(atPath: folder)
                known.listedAt = modified
                known.unreadable.formUnion(names.filter { $0.hasSuffix(".meta.json") && known.toolUseIds[$0] == nil })
            }
        } catch CocoaError.fileReadNoSuchFile {
            // No subagent has written its files yet.
        } catch {
            if unreadableMeta.insert(folder).inserted {
                NSLog("[linkC] a session's subagents folder %@ could not be read — %@", folder, String(describing: error))
            }
        }
        for name in known.unreadable {
            let meta = (folder as NSString).appendingPathComponent(name)
            do {
                let decoded = try JSONDecoder().decode(SubagentMeta.self, from: Data(contentsOf: URL(fileURLWithPath: meta)))
                known.toolUseIds[name] = .some(decoded.toolUseId)
                known.unreadable.remove(name)
            } catch {
                if unreadableMeta.insert(meta).inserted {
                    NSLog("[linkC] a subagent's meta file %@ could not be read — %@", meta, String(describing: error))
                }
            }
        }
    }

    /// The session's running subagents, oldest first, each by the name it was spawned with and the
    /// step its own transcript is on (nil before it has taken one).
    public func sessionSubagentSteps(_ sessionId: String) -> [KnownProject.OpenSession.Subagent] {
        let steps = subagentActivities[sessionId] ?? [:]
        return sessionAgents(sessionId).filter(\.isRunning).map { run in
            KnownProject.OpenSession.Subagent(name: run.description, step: steps[run.id]?.label)
        }
    }

    /// The session's subagent runs, oldest first — spawns and completions from the same
    /// transcript tail that feeds usage.
    public func sessionAgents(_ sessionId: String) -> [AgentRun] {
        agentAssemblers[sessionId]?.runs ?? []
    }

    /// The turn-boundary reset for ALL per-turn transient state: still-running agent runs
    /// are ended (anything "running" past a turn boundary is a phantom) and the current
    /// activity is cleared (a new prompt must never open showing the last turn's action).
    public func sweepAgents(_ sessionId: String, at date: Date = Date()) {
        if activities[sessionId] != nil { activities[sessionId] = nil }
        guard var agents = agentAssemblers[sessionId] else { return }
        agents.endAllRunning(at: date)
        if agentAssemblers[sessionId] != agents { agentAssemblers[sessionId] = agents }
    }

    /// The session's current action ("$ swift test", "✎ PanelView.swift"), nil while idle
    /// or between tools.
    public func sessionActivity(_ sessionId: String) -> String? {
        activities[sessionId]?.label
    }

    /// The conversation's own name — the latest `ai-title` line in its transcript — or nil
    /// before it has been named.
    public func sessionTitle(_ sessionId: String) -> String? {
        titles[sessionId]
    }

    /// Drop every per-session dictionary for an ended session — without this, session ids
    /// (fresh UUIDs, never reused) accumulate for the process lifetime and every refresh
    /// sweep keeps re-reading dead transcripts.
    public func unbind(sessionId: String) {
        sessionPaths[sessionId] = nil
        accumulators[sessionId] = nil
        agentAssemblers[sessionId] = nil
        activities[sessionId] = nil
        titles[sessionId] = nil
        subagentFiles[sessionId] = nil
        subagentActivities[sessionId] = nil
        subagentReaders[sessionId] = nil
        subagentFolders[sessionId] = nil
    }

    public func sessionUsage(_ sessionId: String) -> SessionUsage? {
        guard let acc = accumulators[sessionId], acc.totalTokens > 0 else { return nil }
        return acc.snapshot
    }

    public func refreshAllSessions() {
        for id in sessionPaths.keys { refreshSession(id) }
    }

    // MARK: - Global window

    public func refreshWindow(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        guard let files = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for case let url as URL in files {
            guard url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified >= cutoff else { continue }
            for line in scanReader.readNewLines(at: url.path, firstReadTailCap: Self.firstScanTailCap) {
                guard let usage = TranscriptUsage.parseLine(line) else { continue }
                scanRecords.append(usage)
            }
        }
        scanRecords.removeAll { $0.timestamp < cutoff }
        let computed = UsageWindows.compute(scanRecords, now: now)
        if window != computed { window = computed }
    }

    // MARK: - Accumulation

    private struct Accumulator: Equatable {
        var contextTokens = 0
        var contextModel = ""
        var totalTokens = 0
        var cost = 0.0
        var hasUnpricedTokens = false

        mutating func add(_ usage: MessageUsage) {
            totalTokens += usage.totalTokens
            if let messageCost = ModelPricing.cost(of: usage) {
                cost += messageCost
            } else {
                hasUnpricedTokens = true
            }
            if !usage.isSidechain {
                contextTokens = usage.contextTokens
                contextModel = usage.model
            }
        }

        var snapshot: SessionUsage {
            let windowSize = contextModel.contains("[1m]") ? 1_000_000.0 : 200_000.0
            return SessionUsage(
                contextTokens: contextTokens,
                totalTokens: totalTokens,
                cost: cost,
                hasUnpricedTokens: hasUnpricedTokens,
                contextFill: min(1, Double(contextTokens) / windowSize)
            )
        }
    }
}
