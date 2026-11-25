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
        case .starting: return AgentCardLook(glyph: "◌", label: "starting", tint: .attention, rank: 4)
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

/// A figure on a card's first line: how full its context is, or its agent's tightest plan limit.
public struct AgentMeterLabel: Equatable, Sendable {
    /// `warn` is the mod's orange, `critical` its red.
    public enum Tint: Equatable, Sendable { case muted, warn, critical }

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
    /// How full the context is, beside the model: orange from 80%.
    public let context: AgentMeterLabel?
    /// The agent's tightest plan limit, once it reaches 70%: orange, red from 90%.
    public let limit: AgentMeterLabel?

    /// A redraw lands this long after a label's change, so the label drawn is the new one.
    private static let pastTheChange: TimeInterval = 0.001

    /// `limits` are the plan limits of the session's agent.
    init(session: KnownProject.OpenSession, worktree: String, isSelected: Bool, limits: [KnownLimit]) {
        self.session = session
        self.worktree = worktree
        self.isSelected = isSelected
        cacheExpiry = session.cacheExpiresAt.flatMap(Self.date)
        started = session.since.flatMap(Self.date)
        context = session.contextPercent.map { AgentMeterLabel(text: "\($0)%", tint: $0 >= 80 ? .warn : .muted) }
        limit = Self.tightest(limits)

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
        // shimmer already say it works. What its agent records first-hand (its step, its subagents by
        // name) outranks what its screen shows; what needs you reads its screen and comes first.
        let counted = running > 0 ? Self.subagentWords(running) : ""
        let named = look.needsYou ? "" : Self.namedSubagents(session)
        let doing = look.needsYou ? session.action : (session.step ?? session.action)
        if let doing, !doing.isEmpty {
            words = [doing, named.isEmpty ? counted : named].filter { !$0.isEmpty }.joined(separator: " · ")
        } else if !named.isEmpty {
            words = named
        } else if atWork {
            words = counted.isEmpty ? "" : "running \(counted)"
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

    /// The second line without its worktree, which a view sets apart. A worktree shows alone.
    public var summary: String {
        words.isEmpty && atWork && worktree.isEmpty ? "…" : words
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

    /// The agent as the list names it (`codex`), as the mod shows it.
    private var agentName: String { session.agent }

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

    /// The tightest limit once it reaches 70%; of two as tight, the first listed.
    static func tightest(_ limits: [KnownLimit]) -> AgentMeterLabel? {
        guard let tightest = limits.reduce(nil, { (most: KnownLimit?, limit) in
            most.map { $0.percent >= limit.percent ? $0 : limit } ?? limit
        }), tightest.percent >= 70 else { return nil }
        return AgentMeterLabel(text: "\(tightest.label) \(tightest.percent)%", tint: tightest.percent >= 90 ? .critical : .warn)
    }

    /// The running subagents as the mod names them: the first by name and step, the rest counted, by
    /// the count when it runs ahead of the names.
    static func namedSubagents(_ session: KnownProject.OpenSession) -> String {
        guard let steps = session.subagentSteps, let first = steps.first else { return "" }
        let more = max(steps.count - 1, (session.subagents ?? 0) - 1)
        let step = first.step.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
        return "\(first.name)\(step)\(more > 0 ? " +\(more)" : "")"
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

    /// The column beside session `selectedId`. `limits` are each agent's plan limits, by agent. `roots`
    /// holds each project folder's repo as `RepoRoots` resolved it; a folder git has not answered for
    /// yet joins by lying inside the repo's folder.
    public static func build(projects: [KnownProject], limits: [String: [KnownLimit]], roots: [String: RepoRoots.Root],
                             selectedId: String) -> AgentsColumn {
        guard let home = projects.first(where: { $0.sessions.contains { $0.id == selectedId } }) else { return .pending }
        let root: String
        switch roots[home.path] {
        case nil: return .pending
        case .failed(let why): return AgentsColumn(cards: [], problem: why, isPending: false)
        case .repo(let found): root = found
        }
        let cards = projects.flatMap { project -> [AgentCard] in
            guard let worktree = place(of: project.path, inRepo: root, resolved: roots[project.path]) else { return [] }
            return project.sessions.map {
                AgentCard(session: $0, worktree: worktree, isSelected: $0.id == selectedId, limits: limits[$0.agent] ?? [])
            }
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

/// A terminal's grid as SwiftTerm 1.15.0 lays it out: the font's cell rounded up to the screen's pixel
/// grid (`AppleTerminalView.computeFontDimensions`), across the view less the scroller, which SwiftTerm
/// keeps out of the grid unless the scroller is hidden (`MacTerminalView.getEffectiveWidth`).
public struct TerminalGrid: Equatable, Sendable {
    /// The advance of the font's "W", which SwiftTerm measures a cell by.
    public let fontCellWidth: CGFloat
    /// The screen's pixels per point.
    public let backingScale: CGFloat
    public let scrollerWidth: CGFloat

    public init(fontCellWidth: CGFloat, backingScale: CGFloat, scrollerWidth: CGFloat) {
        self.fontCellWidth = fontCellWidth
        self.backingScale = backingScale
        self.scrollerWidth = scrollerWidth
    }

    /// A cell's width on screen; 0 while there is no font or screen to measure it by.
    public var cellWidth: CGFloat {
        guard fontCellWidth > 0, backingScale > 0 else { return 0 }
        return (fontCellWidth * backingScale).rounded(.up) / backingScale
    }

    /// The columns of a terminal view `width` points wide.
    public func columns(inViewWidth width: CGFloat) -> Int {
        guard cellWidth > 0 else { return 0 }
        return Int((max(0, width - scrollerWidth) / cellWidth).rounded(.down))
    }
}

/// Where the agents column shows beside a terminal, and what its toggle does there.
public enum AgentsColumnPlacement: Equatable, Sendable {
    /// Beside the terminal; the toggle hides it.
    case beside
    /// Off, with room for it; the toggle shows it.
    case hidden
    /// No room beside the terminal: the toggle opens the same cards in a popover.
    case popover
}

/// How wide the column is, and when it gives way to the terminal.
public enum AgentsColumnLayout {
    public static let width: CGFloat = 236
    /// Between the terminal and the column.
    public static let gap: CGFloat = 8
    /// The narrowest terminal the column may leave.
    public static let minimumColumns = 80

    /// Whether the column fits beside the terminal in `paneWidth` points and leaves it at least
    /// `minimumColumns` columns of `grid`.
    public static func fits(paneWidth: CGFloat, grid: TerminalGrid) -> Bool {
        grid.columns(inViewWidth: paneWidth - width - gap) >= minimumColumns
    }

    /// Beside the terminal where the column fits and is on; the popover wherever it does not fit.
    public static func placement(paneWidth: CGFloat, grid: TerminalGrid, isOn: Bool) -> AgentsColumnPlacement {
        guard fits(paneWidth: paneWidth, grid: grid) else { return .popover }
        return isOn ? .beside : .hidden
    }
}

/// What a click on a card does, by where the cards are and where the card's terminal lives.
public enum AgentCardClick: Equatable, Sendable {
    /// Opens the session as a click in its terminal does, and leaves the panel's selection alone.
    case acknowledge
    /// Selects the session as its tab would; one that lives in a window brings that window forward.
    case focus
    /// Selects the session, then shows the panel that holds its terminal.
    case focusShowingPanel
    /// Brings forward the other window that holds the session's terminal, and leaves the panel's
    /// selection alone: selecting it there would close whatever screen the hidden panel had open.
    case raiseWindow

    /// `card` is the clicked card's session and `besideSession` the session the cards are beside;
    /// `inWindow` says the cards are in a torn-off window, `cardInWindow` that the card's terminal is.
    public static func of(card: String, besideSession: String, inWindow: Bool, cardInWindow: Bool) -> AgentCardClick {
        guard inWindow else { return .focus }
        // The window's own session is on screen already: selecting it would move the hidden panel.
        if card == besideSession { return .acknowledge }
        // Selecting a session in the panel shows nothing while the panel is hidden.
        return cardInWindow ? .raiseWindow : .focusShowingPanel
    }
}
