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
        for line in sessionReader.readNewLines(at: path) {
            if let usage = TranscriptUsage.parseLine(line) {
                acc.add(usage)
            }
            // One decode feeds both event consumers (TranscriptUsage keeps its own
            // pricing-critical parser — see TranscriptLine's doc comment).
            if let decoded = TranscriptLine.decode(line) {
                let events = AgentEvents.events(from: decoded)
                if !events.isEmpty { agents.feed(events) }
                activity = ActivityEvents.apply(decoded, to: activity)
            }
        }
        accumulators[sessionId] = acc
        agentAssemblers[sessionId] = agents
        activities[sessionId] = activity
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
        activities[sessionId] = nil
        guard var agents = agentAssemblers[sessionId] else { return }
        agents.endAllRunning(at: date)
        agentAssemblers[sessionId] = agents
    }

    /// The session's current action ("$ swift test", "✎ PanelView.swift"), nil while idle
    /// or between tools.
    public func sessionActivity(_ sessionId: String) -> String? {
        activities[sessionId]?.label
    }

    /// Drop every per-session dictionary for an ended session — without this, session ids
    /// (fresh UUIDs, never reused) accumulate for the process lifetime and every refresh
    /// sweep keeps re-reading dead transcripts.
    public func unbind(sessionId: String) {
        sessionPaths[sessionId] = nil
        accumulators[sessionId] = nil
        agentAssemblers[sessionId] = nil
        activities[sessionId] = nil
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
        window = UsageWindows.compute(scanRecords, now: now)
    }

    // MARK: - Accumulation

    private struct Accumulator {
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
