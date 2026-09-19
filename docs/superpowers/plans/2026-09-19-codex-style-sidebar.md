# Codex-style Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace linkC's home cards, agent banners, header icon bar, and dock with one always-visible Codex-style sidebar (navigation, projects with nested sessions, terminals, servers, cloud, earlier) beside the terminal or screen.

**Architecture:** Every rule (row titles, state text and attention, remembered order/expansion, row building) is a plain type in `LinkCKit`, written test-first. The `linkc` app target stays thin: `AppModel` feeds live data into those types and a 1-second sweep records what is on screen; new SwiftUI views render the result. The panel keeps its frameless glass window and the existing 600pt split breakpoint.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, SwiftPM, XCTest. macOS 14.

**Spec:** `docs/superpowers/specs/2026-09-19-codex-style-sidebar-design.md`

## Global Constraints

- No new dependencies or packages.
- Commit messages must never contain the word "claude" in any case (not even a type name), and carry no `Co-Authored-By`, `Claude-Session`, or "Generated with" trailers. Check with `git log -1 --format=%B | grep -ci claude` → `0`.
- Mock data only in tests. No test-only branches in production code.
- No side effects in SwiftUI view bodies. Anything that writes observable state runs from the app's 1-second sweep or a user action.
- Never `cp` over `~/.local/bin/linkc-mcp`; build the app only with `./build-app.sh`.
- Sidebar width is `Theme.sidebarWidth` (260). The split breakpoint is `Theme.splitBreakpoint` (600).
- Row state text, exactly: `starting`, `idle <age>`, `working`, `needs you · <age>`, `done · <age>`, `rate limited`, `error`. `<age>` is `AgeFormat.compact(from: stateChangedAt, to: now)`.
- Coral = `Theme.accent` (#D97757), for attention only. Working = `Theme.statusRunning` (teal).
- Held-task title format: `Task <shortId>: <first non-empty prompt line>`. Untitled duplicates: `<shortName> 2`, `<shortName> 3`, … per project and agent, in opened order.
- Run one test class with `swift test --filter LinkCKitTests.<ClassName>`; the full suite with `swift test`.

---

### Task 1: Record each conversation's own title in `UsageTracker`

**Files:**
- Create: `Sources/LinkCKit/Usage/ClaudeTitle.swift`
- Modify: `Sources/LinkCKit/Usage/UsageTracker.swift` (stored properties near line 26, `refreshSession` at line 52, `unbind` at line 99)
- Test: `Tests/LinkCKitTests/ClaudeTitleTests.swift`

**Interfaces:**
- Produces: `ClaudeTitle.parse(_ line: String) -> String?`; `UsageTracker.sessionTitle(_ sessionId: String) -> String?`

Claude Code appends lines like `{"type":"ai-title","aiTitle":"Session UI redesign","sessionId":"…"}` to a conversation's transcript; the latest is the current title (5,631 such lines exist on this machine, all with exactly those three keys). `UsageTracker.refreshSession` already reads every line of each bound transcript (the first read has no tail cap), so it records the title as lines pass through.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/ClaudeTitleTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class ClaudeTitleTests: XCTestCase {
    func testParseReturnsTheTitle() {
        let line = #"{"type":"ai-title","aiTitle":"Session UI redesign","sessionId":"s1"}"#
        XCTAssertEqual(ClaudeTitle.parse(line), "Session UI redesign")
    }

    func testParseIgnoresOtherLineTypesEvenWhenTheyMentionTheMarker() {
        let quoted = #"{"type":"user","message":{"content":"grep for \"ai-title\" lines"}}"#
        XCTAssertNil(ClaudeTitle.parse(quoted))
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"assistant","message":{}}"#))
    }

    func testParseRejectsABlankMissingOrMalformedTitle() {
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"ai-title","aiTitle":"   ","sessionId":"s1"}"#))
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"ai-title","sessionId":"s1"}"#))
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"ai-title","aiTitle":"#))
    }
}

@MainActor
final class UsageTrackerTitleTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func titleLine(_ title: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"c1"}"#
    }

    private let userLine = #"{"type":"user","message":{"content":"hi"}}"#

    private func append(_ text: String, to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testTheLatestTitleWinsIncludingOneAppendedAfterTheFirstRead() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try [titleLine("First name"), userLine, titleLine("Second name"), ""].joined(separator: "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        XCTAssertEqual(tracker.sessionTitle("L1"), "Second name")

        try append(titleLine("Renamed") + "\n", to: path)
        tracker.refreshSession("L1")
        XCTAssertEqual(tracker.sessionTitle("L1"), "Renamed")
    }

    func testANewReadWithNoTitleLineKeepsTheEarlierTitle() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try (titleLine("Kept") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        try append(userLine + "\n", to: path)
        tracker.refreshSession("L1")
        XCTAssertEqual(tracker.sessionTitle("L1"), "Kept")
    }

    func testATranscriptWithNoTitleLineHasNoTitle() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try (userLine + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        XCTAssertNil(tracker.sessionTitle("L1"))
    }

    func testUnbindDropsTheTitle() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try (titleLine("Gone soon") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        tracker.unbind(sessionId: "L1")
        XCTAssertNil(tracker.sessionTitle("L1"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.ClaudeTitleTests`
Expected: build FAILS with "cannot find 'ClaudeTitle' in scope" (and `sessionTitle` missing on `UsageTracker`).

- [ ] **Step 3: Write `ClaudeTitle`**

Create `Sources/LinkCKit/Usage/ClaudeTitle.swift`:

```swift
import Foundation

/// Claude Code names each conversation by appending `{"type":"ai-title","aiTitle":"…","sessionId":"…"}`
/// lines to its transcript; the latest one is the current title. The substring check keeps every
/// other line (nearly all of them) from paying a JSON decode.
public enum ClaudeTitle {
    private struct Line: Decodable {
        let type: String
        let aiTitle: String?
    }

    /// The title a transcript line carries, or nil for any other line, a malformed one, or a blank title.
    public static func parse(_ line: String) -> String? {
        guard line.contains("\"ai-title\"") else { return nil }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
              decoded.type == "ai-title",
              let title = decoded.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }
}
```

- [ ] **Step 4: Record titles in `UsageTracker`**

In `Sources/LinkCKit/Usage/UsageTracker.swift`, add a stored property after `private var activities: [String: CurrentActivity] = [:]`:

```swift
    private var titles: [String: String] = [:]
```

Replace the body of `refreshSession(_:)` with:

```swift
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
        accumulators[sessionId] = acc
        agentAssemblers[sessionId] = agents
        activities[sessionId] = activity
        if titles[sessionId] != title { titles[sessionId] = title }
    }
```

Add after `sessionActivity(_:)`:

```swift
    /// The conversation's own name — the latest `ai-title` line in its transcript — or nil
    /// before it has been named.
    public func sessionTitle(_ sessionId: String) -> String? {
        titles[sessionId]
    }
```

In `unbind(sessionId:)`, add `titles[sessionId] = nil` after `activities[sessionId] = nil`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.ClaudeTitleTests && swift test --filter LinkCKitTests.UsageTrackerTitleTests && swift test --filter LinkCKitTests.UsageTrackerTests`
Expected: all PASS.

- [ ] **Step 6: Revert-proof**

Temporarily change `title = named` to `if title == nil { title = named }` (first title wins). Run `swift test --filter LinkCKitTests.UsageTrackerTitleTests` and confirm `testTheLatestTitleWinsIncludingOneAppendedAfterTheFirstRead` FAILS. Restore the line and confirm it passes again.

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Usage/ClaudeTitle.swift Sources/LinkCKit/Usage/UsageTracker.swift Tests/LinkCKitTests/ClaudeTitleTests.swift
git commit -m "feat(usage): keep each conversation's latest ai-title"
```

---

### Task 2: Name each session row

**Files:**
- Create: `Sources/LinkCKit/Core/SessionTitles.swift`
- Modify: `Sources/LinkCKit/Core/AgentKind.swift` (add `shortName` after `displayName`)
- Test: `Tests/LinkCKitTests/SessionTitlesTests.swift`

**Interfaces:**
- Consumes: `Session`, `TaskRecord` (`assigneeSessionId`, `state`, `shortId`, `prompt`), `AgentKind`
- Produces:
  - `AgentKind.shortName: String` — "Claude", "agy", "Cursor", "Codex", "Terminal"
  - `SessionTitles.resolve(sessions: [Session], claudeTitle: (String) -> String?, heldTask: (Session) -> TaskRecord?) -> [String: String]` (keyed by session id)
  - `SessionTitles.taskTitle(_ task: TaskRecord) -> String`
  - `SessionTitles.heldTask(for session: Session, in tasks: [TaskRecord]) -> TaskRecord?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SessionTitlesTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SessionTitlesTests: XCTestCase {
    private func session(_ id: String, _ agent: AgentKind, cwd: String = "/p/linkC") -> Session {
        Session(id: id, cwd: cwd, title: "linkC", agentKind: agent)
    }

    private func task(
        id: String = "a1b2c3d4-0000", assignee: String, state: TaskState,
        prompt: String = "Fix relay dispatch\nDetails"
    ) -> TaskRecord {
        TaskRecord(id: id, fromAgent: .claude, toAgent: .agy, assigneeSessionId: assignee, prompt: prompt, state: state)
    }

    func testTheConversationsOwnTitleWinsOverAHeldTask() {
        let s = session("s1", .claude)
        let held = task(assignee: "s1", state: .started)
        let titles = SessionTitles.resolve(
            sessions: [s], claudeTitle: { $0 == "s1" ? "Session UI redesign" : nil }, heldTask: { _ in held })
        XCTAssertEqual(titles["s1"], "Session UI redesign")
    }

    func testAHeldTaskNamesTheSessionByShortIdAndFirstPromptLine() {
        let s = session("s1", .agy)
        let held = task(assignee: "s1", state: .delivered, prompt: "\n  Fix relay dispatch  \nmore")
        let titles = SessionTitles.resolve(sessions: [s], claudeTitle: { _ in nil }, heldTask: { _ in held })
        XCTAssertEqual(titles["s1"], "Task a1b2c3d4: Fix relay dispatch")
    }

    func testATaskWithABlankPromptIsNamedByShortIdAlone() {
        XCTAssertEqual(SessionTitles.taskTitle(task(assignee: "s1", state: .started, prompt: " \n ")), "Task a1b2c3d4")
    }

    func testUntitledSessionsOfOneAgentInOneProjectAreNumberedInOpenedOrder() {
        let a = session("a", .cursor)
        let b = session("b", .cursor)
        let c = session("c", .agy)
        let d = session("d", .cursor, cwd: "/p/other")
        let titles = SessionTitles.resolve(sessions: [a, b, c, d], claudeTitle: { _ in nil }, heldTask: { _ in nil })
        XCTAssertEqual(titles["a"], "Cursor")
        XCTAssertEqual(titles["b"], "Cursor 2")
        XCTAssertEqual(titles["c"], "agy")
        XCTAssertEqual(titles["d"], "Cursor", "numbering is per project")
    }

    func testATitledSessionDoesNotTakeANumber() {
        let a = session("a", .claude)
        let b = session("b", .claude)
        let titles = SessionTitles.resolve(
            sessions: [a, b], claudeTitle: { $0 == "a" ? "Named" : nil }, heldTask: { _ in nil })
        XCTAssertEqual(titles["b"], "Claude")
    }

    func testTheHeldTaskIsTheDeliveredOrStartedTaskAssignedToTheSession() {
        let s = session("s1", .agy)
        let queued = task(id: "q", assignee: "s1", state: .queued)
        let done = task(id: "d", assignee: "s1", state: .done)
        let other = task(id: "o", assignee: "s2", state: .started)
        let held = task(id: "h", assignee: "s1", state: .started)
        XCTAssertEqual(SessionTitles.heldTask(for: s, in: [queued, done, other, held])?.id, "h")
        XCTAssertNil(SessionTitles.heldTask(for: s, in: [queued, done, other]))
    }

    func testShortNames() {
        XCTAssertEqual(AgentKind.claude.shortName, "Claude")
        XCTAssertEqual(AgentKind.agy.shortName, "agy")
        XCTAssertEqual(AgentKind.cursor.shortName, "Cursor")
        XCTAssertEqual(AgentKind.codex.shortName, "Codex")
        XCTAssertEqual(AgentKind.shell.shortName, "Terminal")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.SessionTitlesTests`
Expected: build FAILS with "cannot find 'SessionTitles' in scope".

- [ ] **Step 3: Add `shortName`**

In `Sources/LinkCKit/Core/AgentKind.swift`, after the `displayName` property, add:

```swift
    /// The short name a sidebar row uses when nothing better names the session.
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .agy: return "agy"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .shell: return "Terminal"
        }
    }
```

- [ ] **Step 4: Write `SessionTitles`**

Create `Sources/LinkCKit/Core/SessionTitles.swift`:

```swift
import Foundation

/// What each session's sidebar row is called. First match wins: the conversation's own title,
/// the task the session is holding, then the agent's short name — numbered " 2", " 3", … when a
/// project has several untitled sessions of one agent, in the order they were opened.
public enum SessionTitles {
    /// Titles for every session, keyed by session id. `sessions` must be in opened order (the
    /// session store's order).
    public static func resolve(
        sessions: [Session],
        claudeTitle: (String) -> String?,
        heldTask: (Session) -> TaskRecord?
    ) -> [String: String] {
        var titles: [String: String] = [:]
        var untitledCount: [String: Int] = [:]   // "<project path>|<agent>" → untitled so far
        for session in sessions {
            if let title = claudeTitle(session.id) {
                titles[session.id] = title
            } else if let task = heldTask(session) {
                titles[session.id] = taskTitle(task)
            } else {
                let key = (session.cwd as NSString).standardizingPath + "|" + session.agentKind.rawValue
                let n = (untitledCount[key] ?? 0) + 1
                untitledCount[key] = n
                titles[session.id] = n == 1 ? session.agentKind.shortName : "\(session.agentKind.shortName) \(n)"
            }
        }
        return titles
    }

    /// "Task <shortId>: <first non-empty line of the prompt>", or "Task <shortId>" for a blank prompt.
    public static func taskTitle(_ task: TaskRecord) -> String {
        let firstLine = task.prompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return "Task \(task.shortId)" }
        return "Task \(task.shortId): \(firstLine)"
    }

    /// The task `session` is working on: assigned to it, and delivered or started.
    public static func heldTask(for session: Session, in tasks: [TaskRecord]) -> TaskRecord? {
        tasks.first { $0.assigneeSessionId == session.id && ($0.state == .delivered || $0.state == .started) }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.SessionTitlesTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Revert-proof**

Temporarily change the numbering key to `session.agentKind.rawValue` alone (drop the project path). Confirm `testUntitledSessionsOfOneAgentInOneProjectAreNumberedInOpenedOrder` FAILS ("Cursor 3" for `d`). Restore and confirm it passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Core/SessionTitles.swift Sources/LinkCKit/Core/AgentKind.swift Tests/LinkCKitTests/SessionTitlesTests.swift
git commit -m "feat(sidebar): name each session row"
```

---

### Task 3: Decide what each session row says and when it wants you

**Files:**
- Create: `Sources/LinkCKit/Core/SessionAttention.swift`
- Test: `Tests/LinkCKitTests/SessionAttentionTests.swift`

**Interfaces:**
- Consumes: `Session` (`id`, `state`, `stateChangedAt`), `SessionState`, `AgeFormat.compact(from:to:)`
- Produces:
  - `SessionRowStatus` (`text: String`, `tone: Tone`, `isCoral: Bool`; `Tone` = `.quiet`, `.working`, `.attention`, `.error`; `init(text:tone:)`)
  - `@MainActor @Observable final class SessionAttention` with `init()`, `markSeen(_ session: Session, at date: Date)`, `retain(only ids: Set<String>)`, `status(for session: Session, onScreen: Bool, rateLimited: Bool, now: Date) -> SessionRowStatus`, `nonisolated static func status(state:stateChangedAt:lastSeen:onScreen:rateLimited:now:) -> SessionRowStatus`, and internal `private(set) var lastSeen: [String: Date]`

"Seen" rule from the spec: a `finished`/`waitingIdle` state is seen when the session is on screen right now, or was marked seen at or after the moment the state began. `markSeen` writes only when the stored date is older than the session's `stateChangedAt`, so a once-a-second caller writes once per state.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SessionAttentionTests.swift`:

```swift
import XCTest
@testable import LinkCKit

@MainActor
final class SessionAttentionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func status(
        _ state: SessionState, lastSeen: Date? = nil, onScreen: Bool = false, rateLimited: Bool = false
    ) -> SessionRowStatus {
        SessionAttention.status(
            state: state, stateChangedAt: t0, lastSeen: lastSeen, onScreen: onScreen,
            rateLimited: rateLimited, now: t0.addingTimeInterval(240))
    }

    func testEachStateReadsAsTheSpecTableSays() {
        XCTAssertEqual(status(.starting), SessionRowStatus(text: "starting", tone: .quiet))
        XCTAssertEqual(status(.ready), SessionRowStatus(text: "idle 4m", tone: .quiet))
        XCTAssertEqual(status(.working), SessionRowStatus(text: "working", tone: .working))
        XCTAssertEqual(status(.waitingPermission), SessionRowStatus(text: "needs you · 4m", tone: .attention))
        XCTAssertEqual(status(.error), SessionRowStatus(text: "error", tone: .error))
        XCTAssertEqual(status(.error, rateLimited: true), SessionRowStatus(text: "rate limited", tone: .error))
    }

    func testAFinishedTurnIsCoralUntilSeen() {
        for state in [SessionState.finished, .waitingIdle] {
            XCTAssertEqual(status(state), SessionRowStatus(text: "done · 4m", tone: .attention))
            XCTAssertEqual(
                status(state, lastSeen: t0.addingTimeInterval(-1)),
                SessionRowStatus(text: "done · 4m", tone: .attention), "seen only before this state began")
            XCTAssertEqual(status(state, lastSeen: t0), SessionRowStatus(text: "idle 4m", tone: .quiet))
            XCTAssertEqual(status(state, onScreen: true), SessionRowStatus(text: "idle 4m", tone: .quiet))
        }
    }

    func testCoralMeansAttentionOrError() {
        XCTAssertTrue(SessionRowStatus(text: "", tone: .attention).isCoral)
        XCTAssertTrue(SessionRowStatus(text: "", tone: .error).isCoral)
        XCTAssertFalse(SessionRowStatus(text: "", tone: .working).isCoral)
        XCTAssertFalse(SessionRowStatus(text: "", tone: .quiet).isCoral)
    }

    func testMarkSeenClearsTheCurrentStateAndANewStateStartsUnseen() {
        let attention = SessionAttention()
        var s = Session(id: "s1", cwd: "/p", title: "p", state: .finished, stateChangedAt: t0)
        let now = t0.addingTimeInterval(60)
        XCTAssertTrue(attention.status(for: s, onScreen: false, rateLimited: false, now: now).isCoral)
        attention.markSeen(s, at: t0.addingTimeInterval(30))
        XCTAssertFalse(attention.status(for: s, onScreen: false, rateLimited: false, now: now).isCoral)
        s.stateChangedAt = t0.addingTimeInterval(90)   // finished again, a later turn
        XCTAssertTrue(attention.status(for: s, onScreen: false, rateLimited: false, now: t0.addingTimeInterval(120)).isCoral)
    }

    func testMarkSeenWritesOncePerState() {
        let attention = SessionAttention()
        let s = Session(id: "s1", cwd: "/p", title: "p", state: .finished, stateChangedAt: t0)
        attention.markSeen(s, at: t0.addingTimeInterval(5))
        attention.markSeen(s, at: t0.addingTimeInterval(6))
        XCTAssertEqual(attention.lastSeen["s1"], t0.addingTimeInterval(5))
    }

    func testRetainDropsGoneSessions() {
        let attention = SessionAttention()
        attention.markSeen(Session(id: "a", cwd: "/p", title: "p", stateChangedAt: t0), at: t0)
        attention.markSeen(Session(id: "b", cwd: "/p", title: "p", stateChangedAt: t0), at: t0)
        attention.retain(only: ["a"])
        XCTAssertEqual(Set(attention.lastSeen.keys), ["a"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.SessionAttentionTests`
Expected: build FAILS with "cannot find 'SessionAttention' in scope".

- [ ] **Step 3: Write `SessionAttention`**

Create `Sources/LinkCKit/Core/SessionAttention.swift`:

```swift
import Foundation
import Observation

/// What a session row says on its right, and a tone the sidebar colors it by. Coral means the
/// session wants you: blocked on a prompt, an error, or a finished turn nobody has looked at yet.
public struct SessionRowStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case quiet, working, attention, error }

    public let text: String
    public let tone: Tone

    public var isCoral: Bool { tone == .attention || tone == .error }

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

/// Remembers when each session was last on screen, so a finished turn reads coral only until the
/// user has looked at it (Codex's unread dot). In memory only: after a relaunch every finished
/// session starts seen.
@MainActor
@Observable
public final class SessionAttention {
    private(set) var lastSeen: [String: Date] = [:]

    public init() {}

    /// Record that `session` is on screen at `date`. Writes only when that changes the outcome —
    /// once per state — so a once-a-second caller does not re-render the sidebar every second.
    public func markSeen(_ session: Session, at date: Date) {
        if (lastSeen[session.id] ?? .distantPast) < session.stateChangedAt {
            lastSeen[session.id] = date
        }
    }

    /// Forget sessions that no longer exist.
    public func retain(only ids: Set<String>) {
        for id in lastSeen.keys where !ids.contains(id) {
            lastSeen[id] = nil
        }
    }

    public func status(for session: Session, onScreen: Bool, rateLimited: Bool, now: Date) -> SessionRowStatus {
        Self.status(
            state: session.state, stateChangedAt: session.stateChangedAt, lastSeen: lastSeen[session.id],
            onScreen: onScreen, rateLimited: rateLimited, now: now)
    }

    /// The spec's state table. `lastSeen` is when the session was last on screen; `onScreen` is
    /// whether it is on screen right now.
    public nonisolated static func status(
        state: SessionState, stateChangedAt: Date, lastSeen: Date?, onScreen: Bool, rateLimited: Bool, now: Date
    ) -> SessionRowStatus {
        let age = AgeFormat.compact(from: stateChangedAt, to: now)
        switch state {
        case .starting:
            return SessionRowStatus(text: "starting", tone: .quiet)
        case .ready:
            return SessionRowStatus(text: "idle \(age)", tone: .quiet)
        case .working:
            return SessionRowStatus(text: "working", tone: .working)
        case .waitingPermission:
            return SessionRowStatus(text: "needs you · \(age)", tone: .attention)
        case .finished, .waitingIdle:
            let seen = onScreen || (lastSeen.map { $0 >= stateChangedAt } ?? false)
            return seen
                ? SessionRowStatus(text: "idle \(age)", tone: .quiet)
                : SessionRowStatus(text: "done · \(age)", tone: .attention)
        case .error:
            return SessionRowStatus(text: rateLimited ? "rate limited" : "error", tone: .error)
        case .ended:
            return SessionRowStatus(text: "ended", tone: .quiet)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.SessionAttentionTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Revert-proof**

Temporarily change `$0 >= stateChangedAt` to `true` (any past look counts). Confirm `testAFinishedTurnIsCoralUntilSeen` and `testMarkSeenClearsTheCurrentStateAndANewStateStartsUnseen` FAIL. Restore and confirm they pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Core/SessionAttention.swift Tests/LinkCKitTests/SessionAttentionTests.swift
git commit -m "feat(sidebar): decide what each session row says and when it wants you"
```

---

### Task 4: Remember project order, expansion, and open sections

**Files:**
- Create: `Sources/LinkCKit/Preferences/SidebarState.swift`
- Test: `Tests/LinkCKitTests/SidebarStateTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class SidebarState` with
  - `enum Section: String, Codable, CaseIterable, Sendable { case more, servers, cloud, earlier }`
  - `init(defaults: UserDefaults = .standard)`
  - `private(set) var projectOrder: [String]`, `private(set) var expandOverrides: [String: Bool]`
  - `noteProjects(_ paths: [String])`, `prune(keeping paths: Set<String>)`, `setExpanded(_ path: String, _ expanded: Bool)`, `noteCoral(_ paths: Set<String>)`, `isOpen(_ section: Section) -> Bool`, `toggle(_ section: Section)`
  - `static let key = "sidebarState"` (internal, for the corrupt-data test)

Every section starts closed (the spec: More, Servers, Cloud, Earlier are all closed by default). A project that just turned coral gets `expandOverrides[path] = true`; while it stays coral a manual collapse sticks.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SidebarStateTests.swift`:

```swift
import XCTest
@testable import LinkCKit

@MainActor
final class SidebarStateTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "linkc-sidebar-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAFreshStateIsEmptyWithEverySectionClosed() {
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, [])
        XCTAssertEqual(state.expandOverrides, [:])
        for section in SidebarState.Section.allCases {
            XCTAssertFalse(state.isOpen(section), "\(section) should start closed")
        }
    }

    func testProjectsKeepTheOrderTheyWereFirstSeenIn() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/a", "/b"])
        state.noteProjects(["/c", "/b", "/a"])
        XCTAssertEqual(state.projectOrder, ["/a", "/b", "/c"])
    }

    func testEverythingSurvivesARelaunch() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/a", "/b"])
        state.setExpanded("/a", true)
        state.toggle(.earlier)
        let reloaded = SidebarState(defaults: defaults)
        XCTAssertEqual(reloaded.projectOrder, ["/a", "/b"])
        XCTAssertEqual(reloaded.expandOverrides, ["/a": true])
        XCTAssertTrue(reloaded.isOpen(.earlier))
        XCTAssertFalse(reloaded.isOpen(.servers))
    }

    func testToggleOpensAndClosesASection() {
        let state = SidebarState(defaults: defaults)
        state.toggle(.more)
        XCTAssertTrue(state.isOpen(.more))
        state.toggle(.more)
        XCTAssertFalse(state.isOpen(.more))
    }

    func testPruneKeepsOnlyFoldersStillInUse() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/a", "/b", "/c"])
        state.setExpanded("/b", true)
        state.prune(keeping: ["/a", "/c"])
        XCTAssertEqual(state.projectOrder, ["/a", "/c"])
        XCTAssertEqual(state.expandOverrides, [:])
        XCTAssertEqual(SidebarState(defaults: defaults).projectOrder, ["/a", "/c"])
    }

    func testAProjectThatTurnsCoralExpandsAndAManualCollapseSticksWhileItStaysCoral() {
        let state = SidebarState(defaults: defaults)
        state.noteCoral(["/a"])
        XCTAssertEqual(state.expandOverrides["/a"], true)
        state.setExpanded("/a", false)
        state.noteCoral(["/a"])
        XCTAssertEqual(state.expandOverrides["/a"], false, "still coral: the manual collapse sticks")
        state.noteCoral([])
        state.noteCoral(["/a"])
        XCTAssertEqual(state.expandOverrides["/a"], true, "coral again: expands again")
    }

    func testUnreadableStoredStateStartsFresh() {
        defaults.set(Data("not json".utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, [])
        XCTAssertEqual(state.expandOverrides, [:])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.SidebarStateTests`
Expected: build FAILS with "cannot find 'SidebarState' in scope".

- [ ] **Step 3: Write `SidebarState`**

Create `Sources/LinkCKit/Preferences/SidebarState.swift`:

```swift
import Foundation
import Observation

/// The sidebar's remembered layout: the order projects were first opened in, per-folder
/// expand/collapse choices, and which collapsible sections are open. Persisted as one JSON value
/// in an injectable UserDefaults suite (as `AppPreferences` is), so tests never touch the real domain.
@MainActor
@Observable
public final class SidebarState {
    public enum Section: String, Codable, CaseIterable, Sendable {
        case more, servers, cloud, earlier
    }

    private struct Stored: Codable {
        var projectOrder: [String] = []
        var expandOverrides: [String: Bool] = [:]
        var openSections: Set<Section> = []
    }

    static let key = "sidebarState"

    public private(set) var projectOrder: [String]
    public private(set) var expandOverrides: [String: Bool]
    private var openSections: Set<Section>
    /// The projects that were coral at the last `noteCoral`. In memory: a project coral at launch
    /// counts as newly coral once.
    @ObservationIgnored private var coralProjects: Set<String> = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var stored = Stored()
        if let data = defaults.data(forKey: Self.key) {
            do {
                stored = try JSONDecoder().decode(Stored.self, from: data)
            } catch {
                NSLog("[linkC] sidebar state is unreadable, starting fresh — %@", String(describing: error))
            }
        }
        projectOrder = stored.projectOrder
        expandOverrides = stored.expandOverrides
        openSections = stored.openSections
    }

    /// Append any project not seen before; everyone else keeps their place.
    public func noteProjects(_ paths: [String]) {
        var order = projectOrder
        for path in paths where !order.contains(path) {
            order.append(path)
        }
        guard order != projectOrder else { return }
        projectOrder = order
        save()
    }

    /// Forget folders that no longer have a live session or an Earlier entry. Run once at launch.
    public func prune(keeping paths: Set<String>) {
        let order = projectOrder.filter { paths.contains($0) }
        let overrides = expandOverrides.filter { paths.contains($0.key) }
        guard order != projectOrder || overrides != expandOverrides else { return }
        projectOrder = order
        expandOverrides = overrides
        save()
    }

    public func setExpanded(_ path: String, _ expanded: Bool) {
        guard expandOverrides[path] != expanded else { return }
        expandOverrides[path] = expanded
        save()
    }

    /// A project that just turned coral expands, overriding a manual collapse. One that stays
    /// coral is left alone, so collapsing it by hand sticks until it next turns coral.
    public func noteCoral(_ paths: Set<String>) {
        let newlyCoral = paths.subtracting(coralProjects)
        coralProjects = paths
        var changed = false
        for path in newlyCoral where expandOverrides[path] != true {
            expandOverrides[path] = true
            changed = true
        }
        if changed { save() }
    }

    public func isOpen(_ section: Section) -> Bool {
        openSections.contains(section)
    }

    public func toggle(_ section: Section) {
        if openSections.contains(section) {
            openSections.remove(section)
        } else {
            openSections.insert(section)
        }
        save()
    }

    private func save() {
        let stored = Stored(projectOrder: projectOrder, expandOverrides: expandOverrides, openSections: openSections)
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
        } catch {
            NSLog("[linkC] sidebar state could not be saved — %@", String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.SidebarStateTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Revert-proof**

Temporarily change `let newlyCoral = paths.subtracting(coralProjects)` to `let newlyCoral = paths`. Confirm `testAProjectThatTurnsCoralExpandsAndAManualCollapseSticksWhileItStaysCoral` FAILS. Restore and confirm it passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Preferences/SidebarState.swift Tests/LinkCKitTests/SidebarStateTests.swift
git commit -m "feat(sidebar): remember project order, expansion, and open sections"
```

---

### Task 5: Build the project and session rows

**Files:**
- Create: `Sources/LinkCKit/Core/SidebarModel.swift`
- Test: `Tests/LinkCKitTests/SidebarModelTests.swift`

**Interfaces:**
- Consumes: `ProjectGroup.group(sessions:)` (groups by standardized cwd, encounter order, `title` = first session's title), `SessionRowStatus` (Task 3)
- Produces:
  - `enum ProjectDot: Equatable, Sendable { case none, working, attention }`
  - `struct SidebarSessionRow: Identifiable, Equatable, Sendable` — `id`, `agentKind`, `title`, `status`
  - `struct SidebarProject: Identifiable, Equatable, Sendable` — `id` (= `path`), `path`, `name`, `dot`, `isExpanded`, `sessions: [SidebarSessionRow]`
  - `enum SidebarModel` with `struct Input { session, title, status, hasRunningSubagents }` (public memberwise `init`) and `static func projects(inputs: [Input], order: [String], expandOverrides: [String: Bool], selectedId: String?) -> [SidebarProject]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SidebarModelTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SidebarModelTests: XCTestCase {
    private func input(
        _ id: String, cwd: String, agent: AgentKind = .claude,
        tone: SessionRowStatus.Tone = .quiet, subagents: Bool = false
    ) -> SidebarModel.Input {
        SidebarModel.Input(
            session: Session(id: id, cwd: cwd, title: URL(fileURLWithPath: cwd).lastPathComponent, agentKind: agent),
            title: "title-\(id)",
            status: SessionRowStatus(text: "text-\(id)", tone: tone),
            hasRunningSubagents: subagents)
    }

    private func build(
        _ inputs: [SidebarModel.Input], order: [String] = [], overrides: [String: Bool] = [:], selected: String? = nil
    ) -> [SidebarProject] {
        SidebarModel.projects(inputs: inputs, order: order, expandOverrides: overrides, selectedId: selected)
    }

    func testProjectsFollowTheStoredOrderAndUnknownOnesComeLastInOpenedOrder() {
        let projects = build(
            [input("1", cwd: "/p/b"), input("2", cwd: "/p/x"), input("3", cwd: "/p/a"), input("4", cwd: "/p/y")],
            order: ["/p/a", "/p/b"])
        XCTAssertEqual(projects.map(\.path), ["/p/a", "/p/b", "/p/x", "/p/y"])
        XCTAssertEqual(projects.map(\.name), ["a", "b", "x", "y"])
    }

    func testSessionsStayInOpenedOrderWithTheirTitlesAndStatuses() {
        let projects = build([input("1", cwd: "/p/a", agent: .agy), input("2", cwd: "/p/b"), input("3", cwd: "/p/a")])
        let a = projects.first { $0.path == "/p/a" }!
        XCTAssertEqual(a.sessions.map(\.id), ["1", "3"])
        XCTAssertEqual(a.sessions[0], SidebarSessionRow(
            id: "1", agentKind: .agy, title: "title-1", status: SessionRowStatus(text: "text-1", tone: .quiet)))
    }

    func testTheDotIsCoralOverTealOverNone() {
        func dot(_ inputs: [SidebarModel.Input]) -> ProjectDot { build(inputs)[0].dot }
        XCTAssertEqual(dot([input("1", cwd: "/p", tone: .working), input("2", cwd: "/p", tone: .attention)]), .attention)
        XCTAssertEqual(dot([input("1", cwd: "/p", tone: .error)]), .attention)
        XCTAssertEqual(dot([input("1", cwd: "/p", tone: .working)]), .working)
        XCTAssertEqual(dot([input("1", cwd: "/p", subagents: true)]), .working)
        XCTAssertEqual(dot([input("1", cwd: "/p")]), .none)
    }

    func testTheSelectedSessionsProjectIsAlwaysExpanded() {
        let projects = build([input("1", cwd: "/p/a")], overrides: ["/p/a": false], selected: "1")
        XCTAssertTrue(projects[0].isExpanded)
    }

    func testOtherwiseTheOverrideDecidesAndTheDefaultIsCollapsed() {
        let projects = build(
            [input("1", cwd: "/p/a"), input("2", cwd: "/p/b"), input("3", cwd: "/p/c")],
            overrides: ["/p/a": true, "/p/b": false])
        XCTAssertEqual(projects.map(\.isExpanded), [true, false, false])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.SidebarModelTests`
Expected: build FAILS with "cannot find 'SidebarModel' in scope".

- [ ] **Step 3: Write `SidebarModel`**

Create `Sources/LinkCKit/Core/SidebarModel.swift`:

```swift
import Foundation

/// A project row's state dot: coral when any session wants you, teal when any is working or has a
/// running subagent, none when everything is idle.
public enum ProjectDot: Equatable, Sendable {
    case none, working, attention
}

/// One session nested under its project in the sidebar.
public struct SidebarSessionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let agentKind: AgentKind
    public let title: String
    public let status: SessionRowStatus

    public init(id: String, agentKind: AgentKind, title: String, status: SessionRowStatus) {
        self.id = id
        self.agentKind = agentKind
        self.title = title
        self.status = status
    }
}

/// One project row: a folder with at least one live session.
public struct SidebarProject: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let dot: ProjectDot
    public let isExpanded: Bool
    public let sessions: [SidebarSessionRow]
}

/// Builds the sidebar's Projects section from live sessions. Pure: every input is a value.
public enum SidebarModel {
    public struct Input: Equatable, Sendable {
        public let session: Session
        public let title: String
        public let status: SessionRowStatus
        public let hasRunningSubagents: Bool

        public init(session: Session, title: String, status: SessionRowStatus, hasRunningSubagents: Bool) {
            self.session = session
            self.title = title
            self.status = status
            self.hasRunningSubagents = hasRunningSubagents
        }
    }

    /// Projects in `order` (the order they were first opened); a project not in `order` goes after
    /// them in encounter order. Sessions stay in `inputs` order (opened order). The selected
    /// session's project is always expanded; otherwise `expandOverrides` decides, default collapsed.
    public static func projects(
        inputs: [Input], order: [String], expandOverrides: [String: Bool], selectedId: String?
    ) -> [SidebarProject] {
        let byId = Dictionary(uniqueKeysWithValues: inputs.map { ($0.session.id, $0) })
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let groups = ProjectGroup.group(sessions: inputs.map(\.session))
        let sorted = groups.enumerated().sorted { a, b in
            (rank[a.element.workspacePath] ?? order.count + a.offset)
                < (rank[b.element.workspacePath] ?? order.count + b.offset)
        }.map(\.element)
        return sorted.map { group in
            let rows = group.sessions.compactMap { byId[$0.id] }
            let holdsSelection = rows.contains { $0.session.id == selectedId }
            return SidebarProject(
                path: group.workspacePath,
                name: group.title,
                dot: dot(for: rows),
                isExpanded: holdsSelection || (expandOverrides[group.workspacePath] ?? false),
                sessions: rows.map {
                    SidebarSessionRow(id: $0.session.id, agentKind: $0.session.agentKind, title: $0.title, status: $0.status)
                }
            )
        }
    }

    static func dot(for rows: [Input]) -> ProjectDot {
        if rows.contains(where: { $0.status.isCoral }) { return .attention }
        if rows.contains(where: { $0.status.tone == .working || $0.hasRunningSubagents }) { return .working }
        return .none
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.SidebarModelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Revert-proof**

Temporarily change `holdsSelection || (expandOverrides[...] ?? false)` to `expandOverrides[group.workspacePath] ?? false`. Confirm `testTheSelectedSessionsProjectIsAlwaysExpanded` FAILS. Restore and confirm it passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Core/SidebarModel.swift Tests/LinkCKitTests/SidebarModelTests.swift
git commit -m "feat(sidebar): build the project and session rows"
```

---

### Task 6: Wire titles, attention, and sidebar state into the app

**Files:**
- Create: `Sources/linkc/AppModel+Sidebar.swift`
- Modify: `Sources/linkc/LinkCApp.swift` (AppModel stored properties near line 121, `panelVisible` at line 101, `start()` at line 186, `startShellSweep()` at line 306, `open`/`goBack`/`focus`/`goHome` at lines 804–864)
- Modify: `Sources/linkc/StatusPanelController.swift` (`observeModel` at line 242, `updateStatusIcon` at line 299)

**Interfaces:**
- Consumes: everything from Tasks 1–5; existing `AppModel` members `sessions`, `selectedId`, `activeScreen`, `panelVisible`, `restorables`, `usage`, `inbox(for:)`, `agentLimit(for:)`, `visibleAgents(_:now:)`, `runningProjectsByPower`, `runningStandaloneByPower`, `dockerVmCpu`, `cloudInstances`, `supabaseProjects`, `configuredEndpoints`, `supabaseNeedsLogin`, `cloudErrors`
- Produces (on `AppModel`, used by Task 7's views):
  - `let attention: SessionAttention`, `let sidebarState: SidebarState`
  - `var onScreenSessionId: String?`
  - `var sessionTitles: [String: String]`
  - `func rowStatus(_ session: Session, now: Date = Date()) -> SessionRowStatus`
  - `func sidebarProjects(now: Date = Date()) -> [SidebarProject]`
  - `var attentionCount: Int`
  - `var serverSummary: Int?` (nil = hide Servers; else running projects + standalone containers)
  - `var cloudSummary: Int?` (nil = hide Cloud; else Oracle + Supabase + watched rows)
  - `func sampleSidebar()`, `func markOnScreenSeen(at now: Date = Date())`

The `linkc` target has no test harness, so this task has no new unit tests: every rule it calls is covered by Tasks 1–5. It is verified by a clean build and the full suite, and visually in Task 8.

- [ ] **Step 1: Add the stored properties**

In `Sources/linkc/LinkCApp.swift`, after `let preferences = AppPreferences()`, add:

```swift
    /// When each session was last on screen — decides whether a finished turn still reads coral.
    let attention = SessionAttention()
    /// The sidebar's remembered project order, expansion, and open sections.
    let sidebarState = SidebarState()
```

- [ ] **Step 2: Create `AppModel+Sidebar.swift`**

Create `Sources/linkc/AppModel+Sidebar.swift`:

```swift
import Foundation
import LinkCKit

/// The sidebar's live inputs. Reads only — the one writer, `sampleSidebar`, runs from the
/// once-a-second shell sweep, never from a view body.
extension AppModel {
    /// The session whose terminal is actually on screen: selected, no screen layered over it,
    /// panel visible.
    var onScreenSessionId: String? {
        guard panelVisible, activeScreen == nil else { return nil }
        return selectedId
    }

    /// Every live session's row title, keyed by session id.
    var sessionTitles: [String: String] {
        SessionTitles.resolve(
            sessions: sessions,
            claudeTitle: { usage.sessionTitle($0) },
            heldTask: { session in
                inbox(for: session.cwd).flatMap { SessionTitles.heldTask(for: session, in: $0.tasks) }
            }
        )
    }

    func rowStatus(_ session: Session, now: Date = Date()) -> SessionRowStatus {
        attention.status(
            for: session,
            onScreen: session.id == onScreenSessionId,
            rateLimited: agentLimit(for: session) != nil,
            now: now
        )
    }

    func sidebarProjects(now: Date = Date()) -> [SidebarProject] {
        let titles = sessionTitles
        let inputs = sessions.map { session in
            SidebarModel.Input(
                session: session,
                title: titles[session.id] ?? session.agentKind.shortName,
                status: rowStatus(session, now: now),
                hasRunningSubagents: visibleAgents(session.id, now: now).contains(where: \.isRunning)
            )
        }
        return SidebarModel.projects(
            inputs: inputs,
            order: sidebarState.projectOrder,
            expandOverrides: sidebarState.expandOverrides,
            selectedId: selectedId
        )
    }

    /// Sessions that want the user — drives the menu-bar tint.
    var attentionCount: Int {
        sessions.count { rowStatus($0).isCoral }
    }

    /// Running compose projects plus standalone containers, or nil when the Servers section hides.
    var serverSummary: Int? {
        let running = runningProjectsByPower.count + runningStandaloneByPower.count
        return (running > 0 || dockerVmCpu != nil) ? running : nil
    }

    /// Oracle, Supabase, and watched rows, or nil when the Cloud section hides.
    var cloudSummary: Int? {
        let rows = cloudInstances.count + supabaseProjects.count + configuredEndpoints.count
        return (rows > 0 || supabaseNeedsLogin || !cloudErrors.isEmpty) ? rows : nil
    }

    /// Once a second: forget ended sessions, mark what is on screen as seen, keep the project
    /// order, and expand projects that just turned coral.
    func sampleSidebar() {
        let now = Date()
        attention.retain(only: Set(sessions.map(\.id)))
        markOnScreenSeen(at: now)
        sidebarState.noteProjects(ProjectGroup.group(sessions: sessions).map(\.workspacePath))
        let coral = sidebarProjects(now: now).filter { $0.dot == .attention }.map(\.path)
        sidebarState.noteCoral(Set(coral))
    }

    /// Mark the on-screen session seen. Also called just before navigation moves it off screen,
    /// so a turn that finished while the user watched never reads as unseen afterwards.
    func markOnScreenSeen(at now: Date = Date()) {
        guard let id = onScreenSessionId, let session = sessions.first(where: { $0.id == id }) else { return }
        attention.markSeen(session, at: now)
    }
}
```

- [ ] **Step 3: Run the sweep and prune at launch**

In `startShellSweep()`, replace `self?.sampleShellAgents()` with:

```swift
                self?.sampleShellAgents()
                self?.sampleSidebar()
```

In `start()`, after `startShellSweep()`, add:

```swift
            // Forget remembered folders with no live session and no Earlier entry.
            let standardized: (String) -> String = { ($0 as NSString).standardizingPath }
            var inUse = Set(sessions.map { standardized($0.cwd) })
            inUse.formUnion(restorables.map { standardized($0.cwd) })
            sidebarState.prune(keeping: inUse)
```

- [ ] **Step 4: Mark the on-screen session seen before navigation**

In `Sources/linkc/LinkCApp.swift`:

Change the `panelVisible` declaration to add a `willSet` (keep the existing `didSet` body unchanged):

```swift
    var panelVisible = false {
        willSet {
            // Hiding the panel takes the open terminal off screen: record it as seen first.
            if !newValue { markOnScreenSeen() }
        }
        didSet {
            updateUsageTimer()
            if !panelVisible {
                flushStateToDisk()
            }
        }
    }
```

Make `markOnScreenSeen()` the first line of each of these methods: `open(_:)`, `goBack()`, `focus(_:)`, `goHome()`. For example:

```swift
    func open(_ screen: PanelScreen) {
        markOnScreenSeen()
        activeScreen = screen
    }
```

- [ ] **Step 5: Tint the menu bar by the new rule**

In `Sources/linkc/StatusPanelController.swift`, replace the tracking closure body in `observeModel()`:

```swift
        withObservationTracking {
            _ = model.selectedId
            _ = model.attentionCount
        } onChange: { [weak self] in
```

and in `updateStatusIcon()` replace `model.needsYouCount > 0` with `model.attentionCount > 0`. Update the doc comment above `updateStatusIcon()` to: "tinted the accent (orange) while any session wants you — blocked, errored, or finished and not yet seen".

- [ ] **Step 6: Build and run the full suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build succeeds with no new warnings in the files touched; the suite reports 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/linkc/AppModel+Sidebar.swift Sources/linkc/LinkCApp.swift Sources/linkc/StatusPanelController.swift
git commit -m "feat(sidebar): wire titles, attention, and sidebar state into the app"
```

---

### Task 7: Replace home and chrome with the sidebar

**Files:**
- Modify: `Sources/LinkCKit/Core/Domain.swift:149` (add `case newSession` to `PanelScreen`)
- Create: `Sources/linkc/Sidebar.swift`
- Create: `Sources/linkc/SessionHeaderStrip.swift`
- Modify: `Sources/linkc/PanelView.swift` (`PanelView` struct lines 11–85, `Pane` enum lines 89–101, `ScreenHost` lines 107–125, `LauncherMenu` line 291)
- Modify: `Sources/linkc/SessionList.swift` (`ServersSection` line 1119, `CloudSection` line 1205)

**Interfaces:**
- Consumes: Task 6's `AppModel` members; existing views `ChromeButton`, `ChromeGlyph`, `EmptyStateView`, `AgentLine`, `AgentReaderView`, `CollisionBanner`, `ProjectDashboardSheet(workspacePath:model:onDismiss:)`, `TerminalContainer`, `ErrorBar`, `SetupErrorView`; `AppModel` actions `focus`, `stop`, `open`, `goBack`, `spawnTeammate(in:agent:)`, `restore(_:as:)`, `restoreAll()`, `dismiss(_:)`, `restoreShell`, `forgetShell`, `stopShell`, `relaunchShell`, `dismissShell`, `installUpdate()`
- Produces: `Sidebar(model:)`, `SessionHeaderStrip(model:session:onBack:onOpenAgent:)`, `PanelScreen.newSession`

The old views (`PanelHeader`, `HomeView`, `TerminalHero`, `SessionListColumn`, `Dock`, …) stay in the tree, unused, until Task 8 deletes them. There is no SwiftUI test harness; the logic under these views is covered by Tasks 1–5, and the pixels are reviewed in Task 8.

- [ ] **Step 1: Add the launcher screen**

In `Sources/LinkCKit/Core/Domain.swift`, add `case newSession` as the first case of `PanelScreen`:

```swift
public enum PanelScreen: String, CaseIterable, Identifiable, Sendable {
    case newSession
    case mcpServers
```

In `Sources/linkc/PanelView.swift`, add to the `switch` in `ScreenHost.content`:

```swift
        case .newSession: EmptyStateView(model: model)
```

Run `swift build 2>&1 | grep -E "error|warning: switch" | head`. If any other `switch` over `PanelScreen` fails to compile, add a `.newSession` arm that matches that switch's purpose (for a label: "New session"; for an icon: "plus").

- [ ] **Step 2: Make the Servers and Cloud sections embeddable**

In `Sources/linkc/SessionList.swift`:
- Change `private struct ServersSection: View` to `struct ServersSection: View` and delete its two lines `SectionHeader(title: "SERVERS")` and the `.padding(.top, 6)` under it.
- Change `private struct CloudSection: View` to `struct CloudSection: View` and delete its two lines `SectionHeader(title: "CLOUD")` and the `.padding(.top, 6)` under it.

The sidebar draws its own collapsible label for each.

- [ ] **Step 3: Move the launcher menu into the sidebar's brand row**

In `Sources/linkc/PanelView.swift`, change `private struct LauncherMenu: View` to `struct LauncherMenu: View`. In its label, change `ChromeGlyph(systemName: "plus", hovering: hovering)` to `ChromeGlyph(systemName: "square.and.pencil", hovering: hovering)`, and change `.help("New session or terminal")` to `.help("New session, terminal, or quit")`.

- [ ] **Step 4: Create the sidebar**

Create `Sources/linkc/Sidebar.swift`:

```swift
import SwiftUI
import AppKit
import LinkCKit

/// The Codex-style sidebar: brand row, navigation, then Projects (sessions nested under each),
/// Terminals, Servers, Cloud, Earlier, and a pinned footer. Plain rows, no cards.
struct Sidebar: View {
    let model: AppModel

    @State private var inspectingWorkspace: String?

    var body: some View {
        VStack(spacing: 0) {
            BrandRow(model: model)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    NavSection(model: model)
                    // Ages and states tick once a second while the sidebar is on screen.
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        ProjectsSection(model: model, now: context.date) { inspectingWorkspace = $0 }
                    }
                    if !model.shellRows.isEmpty {
                        TerminalsSidebarSection(model: model)
                    }
                    if let running = model.serverSummary {
                        CollapsibleSection(title: "Servers", trailing: "\(running) running",
                                           section: .servers, state: model.sidebarState) {
                            ServersSection(model: model)
                        }
                    }
                    if let rows = model.cloudSummary {
                        CollapsibleSection(title: "Cloud", trailing: "\(rows)",
                                           section: .cloud, state: model.sidebarState) {
                            CloudSection(model: model)
                        }
                    }
                    if !model.restorables.isEmpty || !model.restorableShells.isEmpty {
                        EarlierSidebarSection(model: model)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            SidebarFooter(model: model)
        }
        .sheet(isPresented: Binding(
            get: { inspectingWorkspace != nil },
            set: { if !$0 { inspectingWorkspace = nil } }
        )) {
            if let path = inspectingWorkspace {
                ProjectDashboardSheet(workspacePath: path, model: model) { inspectingWorkspace = nil }
            }
        }
    }
}

// MARK: - Rows

/// One plain sidebar row: a 16pt leading glyph, the title, trailing content. A soft pill marks the
/// selected row; hover gets a fainter one. `trailing` receives the hover flag so rows can reveal
/// their actions.
struct SidebarRow<Leading: View, Trailing: View>: View {
    let title: String
    var titleColor: Color = Theme.textPrimary
    var isSelected: Bool = false
    var indent: CGFloat = 0
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: (_ hovering: Bool) -> Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            leading()
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            trailing(hovering)
                .fixedSize()
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.09) : (hovering ? Theme.hover : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help(help ?? title)
    }
}

/// A small hover action glyph inside a row.
private struct RowGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}

/// The agent's color as a small rounded square — how a session row says which agent it is.
private struct AgentMark: View {
    let agent: AgentKind
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Theme.agentColor(agent).opacity(dimmed ? 0.6 : 1))
            .frame(width: 7, height: 7)
    }
}

/// A dim section label; when collapsible, a chevron and a tap to open or close it.
private struct SectionLabel: View {
    let title: String
    var trailing: String? = nil
    var collapsible = false
    var isOpen = true
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if collapsible {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing).monospacedDigit()
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
    }
}

/// A section whose label opens and closes it; the open/closed state is remembered.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    let trailing: String?
    let section: SidebarState.Section
    let state: SidebarState
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(
                title: title, trailing: trailing, collapsible: true,
                isOpen: state.isOpen(section), onToggle: { state.toggle(section) })
            if state.isOpen(section) {
                content()
            }
        }
    }
}

// MARK: - Brand and navigation

private struct BrandRow: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text("linkC")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            LauncherMenu(model: model)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct NavRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    var indent: CGFloat = 0
    let action: () -> Void

    var body: some View {
        SidebarRow(title: title, isSelected: isSelected, indent: indent, action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        } trailing: { _ in
            EmptyView()
        }
    }
}

private struct NavSection: View {
    let model: AppModel

    var body: some View {
        let screen = model.activeScreen
        let showsLauncher = screen == .newSession || (screen == nil && model.selectedId == nil)
        VStack(alignment: .leading, spacing: 1) {
            NavRow(icon: "plus", title: "New session", isSelected: showsLauncher) { model.open(.newSession) }
            NavRow(icon: "bubble.left.and.text.bubble.right", title: "Activity", isSelected: screen == .activity) {
                model.open(.activity)
            }
            NavRow(icon: "wand.and.stars", title: "Skills", isSelected: screen == .skills) { model.open(.skills) }
            NavRow(icon: "server.rack", title: "MCP servers", isSelected: screen == .mcpServers) {
                model.open(.mcpServers)
            }
            NavRow(icon: "ellipsis", title: "More", isSelected: false) { model.sidebarState.toggle(.more) }
            if model.sidebarState.isOpen(.more) {
                NavRow(icon: "shippingbox", title: "Tool servers", isSelected: screen == .toolServers, indent: 16) {
                    model.open(.toolServers)
                }
                NavRow(icon: "terminal", title: "Terminals", isSelected: screen == .terminals, indent: 16) {
                    model.open(.terminals)
                }
                NavRow(icon: "gearshape", title: "Settings", isSelected: screen == .settings, indent: 16) {
                    model.open(.settings)
                }
            }
        }
    }
}

// MARK: - Projects

private struct ProjectsSection: View {
    let model: AppModel
    let now: Date
    let onInspect: (String) -> Void

    var body: some View {
        let projects = model.sidebarProjects(now: now)
        VStack(alignment: .leading, spacing: 1) {
            if !projects.isEmpty {
                SectionLabel(title: "Projects")
            }
            ForEach(projects) { project in
                ProjectRow(project: project, model: model) { onInspect(project.path) }
                if project.isExpanded {
                    ForEach(project.sessions) { row in
                        SessionRow(row: row, isSelected: row.id == model.selectedId, model: model)
                    }
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: SidebarProject
    let model: AppModel
    let onInspect: () -> Void

    var body: some View {
        SidebarRow(
            title: project.name,
            help: (project.path as NSString).abbreviatingWithTildeInPath,
            action: { model.sidebarState.setExpanded(project.path, !project.isExpanded) }
        ) {
            Image(systemName: project.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        } trailing: { hovering in
            HStack(spacing: 6) {
                if hovering {
                    Menu {
                        ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                            Button("Add \(kind.displayName)") { model.spawnTeammate(in: project.path, agent: kind) }
                        }
                    } label: {
                        RowGlyph(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an agent to \(project.name)")
                    Menu {
                        Button("Blackboard & handoff") { onInspect() }
                        Divider()
                        Button("Stop all sessions") {
                            for session in project.sessions { model.stop(session.id) }
                        }
                    } label: {
                        RowGlyph(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More for \(project.name)")
                }
                ProjectDotView(dot: project.dot)
            }
        }
    }
}

private struct ProjectDotView: View {
    let dot: ProjectDot

    var body: some View {
        switch dot {
        case .none:
            Color.clear.frame(width: 6, height: 6)
        case .working:
            Circle()
                .fill(Theme.statusRunning)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.statusRunning.opacity(0.8), radius: 3)
        case .attention:
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
        }
    }
}

private struct SessionRow: View {
    let row: SidebarSessionRow
    let isSelected: Bool
    let model: AppModel

    var body: some View {
        SidebarRow(
            title: row.title,
            isSelected: isSelected,
            indent: 18,
            help: "\(row.agentKind.displayName) — \(row.title)",
            action: { model.focus(row.id) }
        ) {
            AgentMark(agent: row.agentKind)
        } trailing: { hovering in
            HStack(spacing: 6) {
                Text(row.status.text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(color(for: row.status.tone))
                if hovering {
                    Button { model.stop(row.id) } label: { RowGlyph(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Stop this session")
                }
            }
        }
    }

    private func color(for tone: SessionRowStatus.Tone) -> Color {
        switch tone {
        case .quiet: return Theme.textTertiary
        case .working: return Theme.statusRunning
        case .attention: return Theme.accent
        case .error: return Theme.statusError
        }
    }
}

// MARK: - Terminals

private struct TerminalsSidebarSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(title: "Terminals")
            ForEach(model.shellRows) { row in
                ShellSidebarRow(row: row, isSelected: row.id == model.selectedId, model: model)
            }
        }
    }
}

private struct ShellSidebarRow: View {
    let row: ShellRow
    let isSelected: Bool
    let model: AppModel

    private var isRunning: Bool { row.state == .running }

    private var dotColor: Color {
        switch row.state {
        case .running: return Theme.statusRunning
        case .exited(let code): return code == 0 ? Theme.textTertiary : Theme.statusError
        }
    }

    var body: some View {
        SidebarRow(
            title: row.title,
            titleColor: isRunning ? Theme.textPrimary : Theme.textSecondary,
            isSelected: isSelected,
            help: isRunning ? "Open \(row.title)" : "View \(row.title)'s last output",
            action: { model.focus(row.id) }
        ) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        } trailing: { hovering in
            HStack(spacing: 6) {
                if hovering {
                    if isRunning {
                        Button { model.stopShell(row.id) } label: { RowGlyph(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("Stop terminal")
                    } else {
                        Button { model.relaunchShell(row) } label: { RowGlyph(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                            .help("Open a fresh shell in this folder")
                        Button { model.dismissShell(row.id) } label: { RowGlyph(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                    }
                }
                Circle().fill(dotColor).frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Earlier

private struct EarlierSidebarSection: View {
    let model: AppModel

    var body: some View {
        let count = model.restorables.count + model.restorableShells.count
        CollapsibleSection(title: "Earlier", trailing: "\(count)", section: .earlier, state: model.sidebarState) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.restorables) { session in
                    EarlierSessionRow(session: session, model: model)
                }
                ForEach(model.restorableShells) { shell in
                    EarlierShellRow(shell: shell, model: model)
                }
                if model.restorables.count > 1 {
                    Button { model.restoreAll() } label: {
                        Text("Restore all")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 32)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Restore every previous session")
                }
            }
        }
    }
}

private struct EarlierSessionRow: View {
    let session: RestorableSession
    let model: AppModel

    var body: some View {
        SidebarRow(
            title: session.title,
            titleColor: Theme.textSecondary,
            help: "Restore \(session.agentKind.displayName) in \((session.cwd as NSString).abbreviatingWithTildeInPath)",
            action: { model.restore(session) }
        ) {
            AgentMark(agent: session.agentKind, dimmed: true)
        } trailing: { hovering in
            HStack(spacing: 6) {
                if let ended = session.endedLabel(now: Date()) {
                    Text(ended)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                if hovering {
                    Button { model.dismiss(session) } label: { RowGlyph(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                }
            }
        }
        .contextMenu {
            ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                Button("Restore as \(kind.displayName)") { model.restore(session, as: kind) }
            }
        }
    }
}

private struct EarlierShellRow: View {
    let shell: RestorableShell
    let model: AppModel

    var body: some View {
        SidebarRow(
            title: shell.title,
            titleColor: Theme.textSecondary,
            help: shell.command.map { "Re-run: \($0)" } ?? "Open a fresh shell in this folder",
            action: { model.restoreShell(shell) }
        ) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        } trailing: { hovering in
            if hovering {
                Button { model.forgetShell(shell) } label: { RowGlyph(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Forget this terminal")
            }
        }
    }
}

// MARK: - Footer

/// Plan usage on the left, and a round coral install button when a fresh build is waiting.
private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        let usage = model.preferences.showsUsageFooter ? model.windowUsageLabel : nil
        if usage != nil || model.updateAvailable != nil {
            HStack(spacing: 8) {
                if let usage {
                    Text(usage)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let update = model.updateAvailable {
                    Button { model.installUpdate() } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Install & restart · build \(update.fromBuild) → \(update.toBuild)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            }
        }
    }
}
```

- [ ] **Step 5: Create the terminal's header strip**

Create `Sources/linkc/SessionHeaderStrip.swift`:

```swift
import SwiftUI
import LinkCKit

/// The one line above an open terminal: what used to sit on each card. Agent mark, title,
/// "<Agent> · <project>", a subagents chip (a popover of the runs; picking one opens the reader),
/// the session's spend, a 2pt context bar, and the project's collision warning.
struct SessionHeaderStrip: View {
    let model: AppModel
    let session: Session
    let onBack: (() -> Void)?
    let onOpenAgent: (AgentRun) -> Void

    @State private var showsAgents = false

    var body: some View {
        let agents = model.visibleAgents(session.id)
        let title = model.sessionTitles[session.id] ?? session.title
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let onBack {
                    ChromeButton(systemName: "chevron.left", help: "Back", action: onBack)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.agentColor(session.agentKind))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("\(session.agentKind.shortName) · \(URL(fileURLWithPath: session.cwd).lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !agents.isEmpty {
                    Button { showsAgents.toggle() } label: {
                        Text(agents.count == 1 ? "1 subagent ▾" : "\(agents.count) subagents ▾")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsAgents, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(agents) { agent in
                                AgentLine(agent: agent)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        showsAgents = false
                                        onOpenAgent(agent)
                                    }
                            }
                        }
                        .padding(12)
                        .frame(width: 320)
                    }
                }
                if let label = model.selectedUsageLabel {
                    Text(label)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            if let fill = model.contextFill(session.id) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(fill > 0.75 ? Theme.contextWarn : Color.white.opacity(0.3))
                            .frame(width: geo.size.width * fill)
                    }
                }
                .frame(height: 2)
            }
            if let collisions = model.swarm(for: session.cwd)?.collisions, !collisions.isEmpty {
                CollisionBanner(collisions: collisions)
            }
        }
    }
}
```

- [ ] **Step 6: Lay out sidebar + right pane in `PanelView`**

In `Sources/linkc/PanelView.swift`, replace the whole `PanelView` struct (lines 11–85) and the `Pane` enum (lines 89–101) with:

```swift
struct PanelView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let error = model.setupError {
                SetupErrorView(message: error)
            } else {
                VStack(spacing: 0) {
                    // At or above the split breakpoint the sidebar is always there, beside the
                    // right pane. Below it, the sidebar fills the panel and a session or screen
                    // replaces it, with a back button.
                    GeometryReader { geo in
                        ZStack {
                            if geo.size.width >= Theme.splitBreakpoint {
                                HStack(spacing: 0) {
                                    Sidebar(model: model)
                                        .frame(width: Theme.sidebarWidth)
                                    Rectangle()
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: 1)
                                    RightPane(model: model, showsBack: false)
                                }
                            } else if model.selectedId != nil || model.activeScreen != nil {
                                RightPane(model: model, showsBack: true)
                                    .transition(.opacity)
                            } else {
                                Sidebar(model: model)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .animation(Theme.viewSwap, value: Pane(model))
                    }
                    if let error = model.lastError {
                        ErrorBar(message: error)
                            .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Theme.viewSwap, value: model.lastError)
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        // Stock controls (switches, pickers, spinners) inherit the system's blue accent
        // otherwise — the panel is coral everywhere, including its toggles.
        .tint(Theme.accent)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }
}

/// One Equatable discriminator for the pane-swap animation.
private enum Pane: Equatable {
    case terminal, screen(PanelScreen), launcher

    @MainActor init(_ model: AppModel) {
        if let screen = model.activeScreen { self = .screen(screen) }
        else if model.selectedId != nil { self = .terminal }
        else { self = .launcher }
    }
}

/// Whatever is open beside the sidebar: a screen (layered over any open terminal), the selected
/// session's terminal, or the launcher when nothing is open.
private struct RightPane: View {
    let model: AppModel
    let showsBack: Bool

    var body: some View {
        ZStack {
            if let screen = model.activeScreen {
                VStack(spacing: 0) {
                    if showsBack {
                        HStack {
                            ChromeButton(systemName: "chevron.left", help: "Back") { model.goBack() }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    }
                    ScreenHost(model: model, screen: screen)
                }
                .transition(.opacity)
            } else if model.selectedId != nil {
                TerminalPane(model: model, onBack: showsBack ? { model.goBack() } : nil)
                    .transition(.opacity)
            } else {
                EmptyStateView(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.viewSwap, value: Pane(model))
    }
}

/// The open terminal under its header strip. The agent reader swaps in for the terminal until
/// dismissed.
private struct TerminalPane: View {
    let model: AppModel
    let onBack: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.setWindowDraggable) private var setWindowDraggable
    /// An agent opened for reading — replaces the terminal until dismissed.
    @State private var readerAgent: AgentRun?
    /// Whether the pointer is over the terminal (dragging the window is off there).
    @State private var isHoveringTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = model.selectedSession {
                SessionHeaderStrip(model: model, session: session, onBack: onBack) { readerAgent = $0 }
            }
            ZStack {
                if let readerAgent {
                    AgentReaderView(agent: currentAgent(readerAgent)) { self.readerAgent = nil }
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity))
                } else {
                    terminal
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.viewSwap, value: readerAgent?.id)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .onChange(of: model.selectedId, initial: true) { _, _ in
            readerAgent = nil
            styleTerminal(model.selectedTerminal)
        }
    }

    private var terminal: some View {
        ZStack {
            TerminalContainer(session: model.selectedTerminal)
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                .onHover { hovering in
                    let active = hovering && model.selectedTerminal != nil
                    if active != isHoveringTerminal {
                        isHoveringTerminal = active
                        setWindowDraggable(!active)
                    }
                }
                .onDisappear {
                    if isHoveringTerminal {
                        isHoveringTerminal = false
                        setWindowDraggable(true)
                    }
                }
                .onChange(of: model.selectedTerminal?.id) { _, newId in
                    if newId == nil && isHoveringTerminal {
                        isHoveringTerminal = false
                        setWindowDraggable(true)
                    }
                }
            if model.selectedTerminal == nil {
                Text("Select a session")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Re-resolve the opened agent so a completion arriving mid-read fills the body in.
    /// Resolved against the full run list, not `visibleAgents` — a swept run leaves the
    /// visible set, and the reader must not freeze on its "still working" snapshot.
    private func currentAgent(_ agent: AgentRun) -> AgentRun {
        guard let id = model.selectedId else { return agent }
        return model.usage.sessionAgents(id).first { $0.id == agent.id } ?? agent
    }

    /// Restyle the live terminal to the panel's tokens: SF Mono at 12.5 and a translucent
    /// background, so the glass reads through the terminal. The font must be set first and the
    /// layer cleared last: `setupOptions()` re-stamps an opaque layer background on font changes.
    private func styleTerminal(_ session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.30)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
```

- [ ] **Step 7: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error:|warning:" | grep -v "is never used" | head -20; swift test 2>&1 | tail -5`
Expected: no errors; no new warnings except unused-declaration warnings for the old views Task 8 deletes; the suite reports 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/LinkCKit/Core/Domain.swift Sources/linkc/Sidebar.swift Sources/linkc/SessionHeaderStrip.swift Sources/linkc/PanelView.swift Sources/linkc/SessionList.swift
git commit -m "feat(panel): replace home and chrome with a Codex-style sidebar"
```

---

### Task 8: Delete the old views and hand the build over for review

**Files:**
- Delete: `Sources/linkc/Dock.swift`, `Sources/linkc/SessionStrip.swift`
- Modify: `Sources/linkc/PanelView.swift` (delete `PanelHeader`, `TopNavBar`, `CountBadge`, `HomeView`, `PreviewText`, `TerminalHero`, `UpdateBar`)
- Rename + modify: `Sources/linkc/SessionList.swift` → `Sources/linkc/SidebarInfra.swift`
- Modify: `Sources/linkc/AppModel+Sidebar.swift` (receives `agentLimit(for:)`)
- Modify: `Sources/linkc/Theme.swift` (delete `dockBreakpoint`, `dockInset`, `previewHeight`)
- Modify: `Sources/linkc/LinkCApp.swift` (delete members left unused)

**Interfaces:**
- Consumes: the finished Task 7 panel.
- Produces: no new API. Nothing outside `Sources/linkc` changes.

- [ ] **Step 1: Delete the replaced views**

```bash
git rm Sources/linkc/Dock.swift Sources/linkc/SessionStrip.swift
git mv Sources/linkc/SessionList.swift Sources/linkc/SidebarInfra.swift
```

In `Sources/linkc/PanelView.swift`, delete the structs `PanelHeader`, `TopNavBar`, `CountBadge`, `HomeView`, `PreviewText`, `TerminalHero`, and `UpdateBar`, with their doc comments and `// MARK:` headers. Keep `SectionHeader` (other screens use it), `ChromeButton`, `ChromeGlyph`, `LauncherMenu`, `EmptyStateView` and its helpers, `QuietLink`, `SetupErrorView`, `ErrorBar`, and `PrimaryButtonStyle`.

In `Sources/linkc/SidebarInfra.swift`, delete `SessionListColumn`, `TerminalsSection`, `RestorableShellRow`, `EarlierSection`, `RestorableRow`, `AgentMiniLaneView`, `HomeCard`, `CompactProjectRow`, `CompactTerminalRow`, and the `statusLabel(_:)` function. Move `agentLimit(for:)` from the file's `extension AppModel` into the extension in `Sources/linkc/AppModel+Sidebar.swift`, and delete `delegatedTask(for:)`. Keep `ServersSection`, `CloudSection`, and every row, header, and helper they use.

In `Sources/linkc/Theme.swift`, delete `dockBreakpoint`, `dockInset`, and `previewHeight` with their comments.

- [ ] **Step 2: Build, then delete whatever is now unused**

Run `swift build 2>&1 | grep error: | head -20` and fix each error by deleting the stale reference.

Then find `AppModel` members and views left with no callers:

```bash
for sym in needsYouCount activeCount projectGroups showsSessionStrip recentOutput goHome currentActivity shellActivity \
           AgentChip StatusDot AgentPill SwarmBadge smoothShimmer planeCard activityIcon InfraDot CompactRowShell \
           CompactRowGlyph QuietLink FolderChip; do
  uses=$(grep -rnw "$sym" Sources/linkc | grep -v -E "(struct|func|var|let|extension) $sym\b" | wc -l | tr -d ' ')
  echo "$sym $uses"
done
```

Delete every symbol that reports `0` — its definition, doc comment, and any helper only it used — then repeat the loop until nothing new reports `0`. Any `// MARK:` header left with nothing under it goes too. Check `goHome()`: if its only callers were deleted views, delete it and its `markOnScreenSeen()` line with it.

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error:|warning:" | head -20; swift test 2>&1 | tail -5`
Expected: no errors, no warnings in `Sources/linkc`, and the suite reports 0 failures.

- [ ] **Step 4: Build the app bundle**

Run: `./build-app.sh 2>&1 | tail -3`
Expected: ends with `==> Done: /Users/jacobdang/projects/linkC/dist.noindex/linkC.app`.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/linkc
git commit -m "refactor(panel): delete the cards, dock, header, and session strip"
git log -1 --format=%B | grep -ci claude   # must print 0
```

- [ ] **Step 6: Hand over for visual review**

The installed app is what the user runs, and installing restarts every hosted agent session, so the controller does not install it. Report that the build is ready, and ask the user to install it with the running app's "Install & restart" and send screenshots at their normal size (1365×788) and at under 600pt wide. Visual fixes from that review are follow-up commits on this branch.
