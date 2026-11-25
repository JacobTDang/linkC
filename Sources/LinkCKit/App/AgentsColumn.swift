import CoreGraphics
import Foundation

/// How a card's state reads on its second line, and where the card sorts: what needs you first.
public struct AgentCardLook: Equatable, Sendable {
    public enum Tint: Equatable, Sendable { case attention, error, working, done, muted }

    public let glyph: String
    public let label: String
    public let tint: Tint
    /// 0–2 need you (a permission, an error, a wait for input), 3 is at work, then the rest.
    public let rank: Int

    static let workingRank = 3

    public var needsYou: Bool { rank < Self.workingRank }
    /// At work: its line shimmers.
    public var isWorking: Bool { rank == Self.workingRank }

    static let idle = AgentCardLook(glyph: "○", label: "idle", tint: .muted, rank: 6)

    static func of(_ state: SessionState) -> AgentCardLook {
        switch state {
        case .waitingPermission: return AgentCardLook(glyph: "!", label: "needs permission", tint: .attention, rank: 0)
        case .error: return AgentCardLook(glyph: "✗", label: "error", tint: .error, rank: 1)
        case .waitingIdle: return AgentCardLook(glyph: "●", label: "waiting for you", tint: .attention, rank: 2)
        case .working: return AgentCardLook(glyph: "●", label: "working", tint: .working, rank: workingRank)
        case .starting: return AgentCardLook(glyph: "◌", label: "starting", tint: .muted, rank: 4)
        case .finished: return AgentCardLook(glyph: "✓", label: "done", tint: .done, rank: 5)
        case .ready: return AgentCardLook(glyph: "○", label: "ready", tint: .muted, rank: 6)
        // The list holds live sessions only; an ended one would read as idle.
        case .ended: return idle
        }
    }

    /// The coarse activity, for a state this build does not know.
    static func of(_ activity: KnownProject.OpenSession.Activity) -> AgentCardLook {
        switch activity {
        case .busy: return AgentCardLook(glyph: "●", label: "busy", tint: .working, rank: workingRank)
        case .starting: return of(SessionState.starting)
        case .idle: return idle
        }
    }

    static func running(_ subagents: Int) -> AgentCardLook {
        AgentCardLook(glyph: "●", label: "running \(AgentCard.subagentWords(subagents))", tint: .working, rank: workingRank)
    }
}

/// When a card's prompt cache goes cold: `~` marks a guess.
public struct AgentCacheLabel: Equatable, Sendable {
    /// `soon` is the last five minutes.
    public enum Tint: Equatable, Sendable { case muted, soon, cold }

    public let text: String
    public let tint: Tint

    public init(text: String, tint: Tint) {
        self.text = text
        self.tint = tint
    }
}

/// One session's card beside a terminal, as the linkc-agents mod draws it inside the agent CLI
/// (mods/linkc-agents/hooks/register.tsx).
public struct AgentCard: Equatable, Sendable, Identifiable {
    /// The session as the app published it. The card reads everything from it, so a field the list
    /// gains reaches the card with no other path.
    public let session: KnownProject.OpenSession
    /// The worktree (or subfolder) the session runs in; empty in the repo's own checkout.
    public let worktree: String
    /// The session whose terminal the column sits beside.
    public let isSelected: Bool
    public let look: AgentCardLook
    /// What the second line says before the worktree: the action, the running subagents or the
    /// state's words. Empty for a session at work that nothing has been said about yet.
    private let words: String
    private let atWork: Bool
    private let cacheExpiry: Date?
    private let started: Date?

    /// A redraw lands this long after a label's change, so the label drawn is the new one.
    private static let pastTheChange: TimeInterval = 0.001

    init(session: KnownProject.OpenSession, worktree: String, isSelected: Bool) {
        self.session = session
        self.worktree = worktree
        self.isSelected = isSelected
        cacheExpiry = session.cacheExpiresAt.flatMap(Self.date)
        started = session.since.flatMap(Self.date)

        let state = session.state.flatMap(SessionState.init(rawValue:))
        let atWork = state.map { $0 == .working } ?? (session.activity == .busy)
        self.atWork = atWork
        let running = session.subagents ?? 0
        let base = state.map(AgentCardLook.of) ?? AgentCardLook.of(session.activity)
        // A session whose own turn ended while its subagents still run is at work, not idle or waiting;
        // a permission wait or an error still comes first.
        let look = running == 0 || atWork || state == .waitingPermission || state == .error ? base : .running(running)
        self.look = look

        // A session at work shows what it does, never the word for its state: the dot and the
        // shimmer already say it works.
        let subagents = running > 0 ? Self.subagentWords(running) : ""
        if let action = session.action, !action.isEmpty {
            words = [action, subagents].filter { !$0.isEmpty }.joined(separator: " · ")
        } else if atWork {
            words = subagents.isEmpty ? "" : "running \(subagents)"
        } else {
            words = look.label
        }
    }

    /// The second line after the glyph: `summary`, then the worktree.
    public var detail: String {
        let line = [words, worktree].filter { !$0.isEmpty }.joined(separator: " ")
        // A session at work that nothing has been said about yet still shimmers on something.
        return line.isEmpty && atWork ? "…" : line
    }

    /// The second line without its worktree, which a view sets apart.
    public var summary: String {
        words.isEmpty && atWork ? "…" : words
    }

    public var id: String { session.id }
    public var agentKind: AgentKind? { session.agentKind }
    public var title: String { session.title ?? agentName }
    public var isWorking: Bool { look.isWorking }

    /// The model as a person names it, else the agent when the title does not already name it; a
    /// worker says so.
    public var subtitle: String {
        let who = session.model.map(Self.modelLabel) ?? (session.title == nil ? nil : agentName)
        return [who, session.worker == true ? "worker" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var agentName: String { session.agentKind?.shortName ?? session.agent }

    /// Whole minutes left, rounded down, so a cache never reads warm after it went cold.
    public func cache(at now: Date) -> AgentCacheLabel? {
        guard let cacheExpiry else { return nil }
        let left = cacheExpiry.timeIntervalSince(now)
        if left <= 0 { return AgentCacheLabel(text: "◷ cold", tint: .cold) }
        let minutes = Int((left / 60).rounded(.down))
        let span = minutes >= 60 ? "\(minutes / 60)h" : minutes >= 1 ? "\(minutes)m" : "<1m"
        return AgentCacheLabel(text: "◷ \(session.cacheEstimate == true ? "~" : "")\(span)", tint: left <= 5 * 60 ? .soon : .muted)
    }

    /// How long the session has been in its state.
    public func age(at now: Date) -> String {
        guard let started else { return "" }
        let minutes = Int((now.timeIntervalSince(started) / 60).rounded(.down))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }

    /// The first moment after `now` that the age or the cache clock reads differently.
    func nextChange(after now: Date) -> Date? {
        var changes: [Date] = []
        if let started {
            let minutes = max(0, (now.timeIntervalSince(started) / 60).rounded(.down))
            changes.append(started + (minutes + 1) * 60 + Self.pastTheChange)
        }
        if let cacheExpiry, cacheExpiry > now {
            // Reads `m` whole minutes until exactly m minutes are left, then m - 1; at none left, cold.
            let minutes = (cacheExpiry.timeIntervalSince(now) / 60).rounded(.down)
            changes.append(cacheExpiry - minutes * 60 + Self.pastTheChange)
        }
        return changes.filter { $0 > now }.min()
    }

    /// A model as a person reads it. A name the agent already gave (`Opus 5.5`) stays; a Claude id reads
    /// as its family and version (`claude-opus-5-5` → `Opus 5.5`); any other id keeps its name and
    /// version joined and spaces the rest (`gemini-3.8-flash-medium` → `gemini-3.8 flash medium`).
    public static func modelLabel(_ model: String) -> String {
        if model.contains(where: { $0 == " " || ($0.isUppercase && $0.isASCII) }) { return model }
        func named(_ family: Substring, _ major: Substring, _ minor: Substring?) -> String {
            "\(family.prefix(1).uppercased())\(family.dropFirst()) \(major)\(minor.map { ".\($0)" } ?? "")"
        }
        // claude-opus-5-5, claude-opus-4-20250514 (no minor, a date), and the older claude-3-5-sonnet-20241022.
        if let match = model.wholeMatch(of: /claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?/) {
            return named(match.1, match.2, match.3)
        }
        if let match = model.wholeMatch(of: /claude-(\d+)(?:-(\d{1,2}))?-([a-z]+)(?:-\d{8})?/) {
            return named(match.3, match.1, match.2)
        }
        let parts = model.split(separator: "-", omittingEmptySubsequences: false)
        guard let version = parts.firstIndex(where: { $0.wholeMatch(of: /\d+(\.\d+)*/) != nil }) else { return model }
        return ([parts[...version].joined(separator: "-")] + parts[(version + 1)...].map(String.init)).joined(separator: " ")
    }

    static func subagentWords(_ count: Int) -> String {
        "\(count) subagent\(count == 1 ? "" : "s")"
    }

    /// An ISO 8601 time as the app publishes it, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// The column of agent cards beside a session's terminal: every session of that session's repo, its
/// worktrees included, what needs you first.
public struct AgentsColumn: Equatable, Sendable {
    public let cards: [AgentCard]
    /// Said above the cards: why git could not tell the repo, or a card's unreadable time.
    public let problem: String?
    /// The session's own repo is not known yet: git has not answered, or the session is not in the
    /// published list yet. Not the same as a repo with no sessions.
    public let isPending: Bool

    static let pending = AgentsColumn(cards: [], problem: nil, isPending: true)

    public var needsYou: Int { cards.filter(\.look.needsYou).count }
    public var needsYouLabel: String? { needsYou > 0 ? "\(needsYou) need you" : nil }
    public var countLabel: String { "\(cards.count)" }

    /// The column beside session `selectedId`. `roots` holds each project folder's repo as `RepoRoots`
    /// resolved it; a folder git has not answered for yet joins by lying inside the repo's folder.
    public static func build(projects: [KnownProject], roots: [String: RepoRoots.Root], selectedId: String) -> AgentsColumn {
        guard let home = projects.first(where: { $0.sessions.contains { $0.id == selectedId } }) else { return .pending }
        let root: String
        switch roots[home.path] {
        case nil: return .pending
        case .failed(let why): return AgentsColumn(cards: [], problem: why, isPending: false)
        case .repo(let found): root = found
        }
        let cards = projects.flatMap { project -> [AgentCard] in
            guard let worktree = place(of: project.path, inRepo: root, resolved: roots[project.path]) else { return [] }
            return project.sessions.map { AgentCard(session: $0, worktree: worktree, isSelected: $0.id == selectedId) }
        }
        let unreadable = cards.first { card in card.session.cacheExpiresAt.map { AgentCard.date($0) == nil } ?? false }
        let problem = unreadable.map { "session \($0.id)'s cache time \"\($0.session.cacheExpiresAt ?? "")\" is not a time" }
        return AgentsColumn(cards: cards.sorted(by: inOrder), problem: problem, isPending: false)
    }

    /// The first moment after `now` that any card's age or cache clock reads differently.
    public func nextRedraw(after now: Date) -> Date? {
        cards.compactMap { $0.nextChange(after: now) }.min()
    }

    /// Where `path` sits in the repo at `root`: empty for the repo's own folder, a worktree's name, else
    /// its last folder; nil for a folder of another repo.
    static func place(of path: String, inRepo root: String, resolved: RepoRoots.Root?) -> String? {
        let inside = path == root || path.hasPrefix(root + "/")
        if case .repo(let own) = resolved {
            guard own == root else { return nil }
        } else if !inside {
            return nil
        }
        if path == root { return "" }
        guard inside else { return URL(fileURLWithPath: path).lastPathComponent }
        let below = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        if let mark = below.firstIndex(where: { $0 == "worktrees" || $0 == ".worktrees" }), mark + 1 < below.count {
            return below[mark + 1]
        }
        return below.last ?? ""
    }

    private static func inOrder(_ a: AgentCard, _ b: AgentCard) -> Bool {
        if a.look.rank != b.look.rank { return a.look.rank < b.look.rank }
        let byTitle = a.title.localizedCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.id < b.id
    }
}

/// How wide the column is, and when it gives way to the terminal.
public enum AgentsColumnLayout {
    public static let width: CGFloat = 236
    /// Between the terminal and the column.
    public static let gap: CGFloat = 8
    /// The narrowest terminal the column may leave.
    public static let minimumColumns: CGFloat = 80

    /// Whether the column fits beside the terminal in `paneWidth` points and leaves it at least
    /// `minimumColumns` cells of `cellWidth`.
    public static func fits(paneWidth: CGFloat, cellWidth: CGFloat) -> Bool {
        guard cellWidth > 0 else { return false }
        return ((paneWidth - width - gap) / cellWidth).rounded(.down) >= minimumColumns
    }
}
