# Sessions Sidebar + Phantom-Agent Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the home session list beside the open terminal (split layout), and stop finished subagents from showing as "running" forever.

**Architecture:** SwiftUI menu-bar panel (`Sources/linkc`) over a logic kit (`Sources/LinkCKit`). The home list is extracted into a reusable `SessionListColumn` that `TerminalHero` renders as a fixed 260pt sidebar when the pane is ≥600pt wide. The agent fix hardens transcript parsing in `AgentEvents` (tolerant per-block decoding, string-or-array tool_result content, empty results count as completions) and adds a turn-over sweep that ends any run whose completion never arrived.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, SwiftPM, XCTest. Build: `swift build`. Tests: `swift test`.

**Spec:** `docs/superpowers/specs/2026-08-17-sessions-sidebar-and-agent-fix-design.md`

## Global Constraints

- Work on branch `sessions-sidebar` off `main`.
- Commit messages: plain descriptive title (match repo style, e.g. "Session strip: mini-tabs above the open terminal"), **no AI/assistant mentions, no co-author trailers**.
- Fail loud — no swallowed errors, no silent fallbacks that mask bugs. (The tolerant decoding below is deliberate spec-mandated resilience to known transcript shape variance, not error swallowing.)
- No new dependencies.
- LinkCKit logic is unit-tested (TDD). SwiftUI/AppKit view code in `Sources/linkc` has no test harness in this repo — for those tasks the cycle is: build clean, full test suite green, visual verification in Task 7.
- Match surrounding code style: doc comments explain constraints/why, tokens come from `Theme`, Reduce Motion is honored at call sites.

## Spec deviations (agreed rationale)

1. The spec says the panel "already widens when a session is selected" — that comment in `StatusPanelController.swift` is stale; the code keeps one persisted size. Task 6 (re)introduces widening on selection.
2. The spec's sweep list "ready / waiting / finished / ended": `waitingPermission` is **excluded** from the sweep — a permission prompt pauses mid-turn and a sync subagent may legitimately still be alive then. The sweep fires on `.ready`, `.waitingIdle`, `.finished`, `.error`, `.ended`.

---

### Task 0: Branch

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/jacobdang/projects/linkC
git checkout main && git pull && git checkout -b sessions-sidebar
```

---

### Task 1: Tolerant transcript parsing in AgentEvents

**Files:**
- Modify: `Sources/LinkCKit/Usage/AgentEvents.swift`
- Test: `Tests/LinkCKitTests/AgentEventsTests.swift`

**Interfaces:**
- Consumes: existing `AgentEvents.parse(line:) -> [AgentEvent]`.
- Produces: same public signature; new behavior — string-content tool_results parse, malformed blocks are skipped individually, empty tool_results emit `.completed(toolUseId:resultText:nil,at:)`.

- [ ] **Step 1: Write the failing tests**

Add to `final class AgentEventsTests` in `Tests/LinkCKitTests/AgentEventsTests.swift`:

```swift
func testStringContentToolResultCompletes() throws {
    // Real transcripts sometimes carry tool_result content as a bare string, not a block array.
    let line = """
    {"type":"user","timestamp":"2026-07-23T04:05:00Z","message":{"content":[\
    {"type":"tool_result","tool_use_id":"toolu_A","content":"plain string result"}]}}
    """
    let events = AgentEvents.parse(line: line)
    XCTAssertEqual(events.count, 1)
    guard case .completed(let id, let result, _) = events[0] else { return XCTFail() }
    XCTAssertEqual(id, "toolu_A")
    XCTAssertEqual(result, "plain string result")
}

func testMalformedBlockDoesNotDropSiblings() throws {
    // One undecodable block (input as a bare string) must not erase the whole line's events.
    let line = """
    {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
    {"type":"tool_use","id":"toolu_X","name":"Agent","input":"garbage-shape"},\
    {"type":"tool_use","id":"toolu_A","name":"Agent",\
    "input":{"description":"Survey","subagent_type":"Explore"}}]}}
    """
    let events = AgentEvents.parse(line: line)
    XCTAssertEqual(events.count, 1)
    guard case .spawned(let id, let description, _, _) = events[0] else { return XCTFail() }
    XCTAssertEqual(id, "toolu_A")
    XCTAssertEqual(description, "Survey")
}

func testEmptyToolResultStillCompletes() throws {
    // A completion with no text is still a completion — dropping it strands the run as "running".
    let line = """
    {"type":"user","timestamp":"2026-07-23T04:05:00Z","message":{"content":[\
    {"type":"tool_result","tool_use_id":"toolu_A","content":[]}]}}
    """
    let events = AgentEvents.parse(line: line)
    XCTAssertEqual(events.count, 1)
    guard case .completed(let id, let result, _) = events[0] else { return XCTFail() }
    XCTAssertEqual(id, "toolu_A")
    XCTAssertNil(result)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter AgentEventsTests
```

Expected: the three new tests FAIL (`events.count` is 0 — string content and malformed siblings kill the line today; empty results are skipped). All pre-existing tests PASS.

- [ ] **Step 3: Implement tolerant decoding**

In `Sources/LinkCKit/Usage/AgentEvents.swift`:

3a. Replace the `tool_result` branch of `parse(line:)` (currently the `guard !text.isEmpty, !text.hasPrefix(asyncLaunchMarker)` block):

```swift
if block.type == "tool_result", let id = block.toolUseId {
    let text = block.content?.joinedText ?? ""
    // Async agents' immediate tool_result is launch metadata, not a completion.
    guard !text.hasPrefix(asyncLaunchMarker) else { continue }
    // An empty result still completes the run — dropping it strands the run as running.
    events.append(.completed(toolUseId: id, resultText: text.isEmpty ? nil : text, at: timestamp))
}
```

3b. Replace `RawContent`'s init so one malformed block is skipped alone:

```swift
/// User-message content is a string OR a block array; both occur in real transcripts.
/// Blocks decode individually — one malformed block is skipped alone rather than
/// discarding every event in the line.
private enum RawContent: Decodable {
    case text(String)
    case blocks([RawBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            let failables = (try? container.decode([FailableBlock].self)) ?? []
            self = .blocks(failables.compactMap(\.block))
        }
    }
}

/// Always decodes; `block` is nil when the element didn't match `RawBlock`. Wrapping each
/// element keeps the array's decode cursor advancing past bad entries.
private struct FailableBlock: Decodable {
    let block: RawBlock?

    init(from decoder: Decoder) throws {
        block = try? RawBlock(from: decoder)
    }
}
```

3c. Change `RawBlock.content` from `[RawResultContent]?` to a string-or-array payload:

```swift
private struct RawBlock: Decodable {
    let type: String?
    let id: String?
    let name: String?
    let text: String?
    let input: RawInput?
    let toolUseId: String?
    let content: RawResultPayload?

    enum CodingKeys: String, CodingKey {
        case type, id, name, text, input, content
        case toolUseId = "tool_use_id"
    }
}

/// tool_result content: a block array in most transcripts, a bare string in some.
private enum RawResultPayload: Decodable {
    case text(String)
    case blocks([RawResultContent])

    var joinedText: String {
        switch self {
        case .text(let string): return string
        case .blocks(let blocks): return blocks.compactMap(\.text).joined(separator: "\n")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .blocks(try container.decode([RawResultContent].self))
        }
    }
}
```

The old `let text = (block.content ?? []).compactMap(\.text).joined(separator: "\n")` line is gone (replaced in 3a). `RawResultContent` itself is unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter AgentEventsTests
```

Expected: ALL pass, including `testAsyncLaunchResultIsNotCompletion`, `testSyncToolResultCompletes`, `testTaskNotificationCompletes`, `testGarbageAndUnrelatedLinesAreEmpty`.

- [ ] **Step 5: Full suite, then commit**

```bash
swift test
git add Sources/LinkCKit/Usage/AgentEvents.swift Tests/LinkCKitTests/AgentEventsTests.swift
git commit -m "Agent transcript parsing: per-block tolerant decode, string results, empty completions"
```

---

### Task 2: Assembler sweep + late-completion fill

**Files:**
- Modify: `Sources/LinkCKit/Usage/AgentEvents.swift` (the `AgentAssembler` at the bottom)
- Test: `Tests/LinkCKitTests/AgentEventsTests.swift`

**Interfaces:**
- Consumes: `AgentAssembler.feed(_:)`, `AgentRun`.
- Produces: `public mutating func endAllRunning(at date: Date)` on `AgentAssembler`; `feed` now lets a late real completion fill `resultText` on an already-ended run (keeping the earlier `endedAt`).

- [ ] **Step 1: Write the failing tests**

Add to `AgentEventsTests`:

```swift
func testEndAllRunningSweepsOpenRuns() {
    var assembler = AgentAssembler()
    let t0 = Date(timeIntervalSince1970: 1_784_692_800)
    assembler.feed([
        .spawned(toolUseId: "toolu_A", description: "Survey", type: "Explore", at: t0),
        .spawned(toolUseId: "toolu_B", description: "Design", type: "Plan", at: t0),
    ])
    assembler.feed([.completed(toolUseId: "toolu_A", resultText: "done", at: t0.addingTimeInterval(60))])

    assembler.endAllRunning(at: t0.addingTimeInterval(90))

    let a = assembler.runs.first { $0.id == "toolu_A" }!
    XCTAssertEqual(a.endedAt, t0.addingTimeInterval(60), "already-ended runs keep their real end")
    let b = assembler.runs.first { $0.id == "toolu_B" }!
    XCTAssertFalse(b.isRunning)
    XCTAssertEqual(b.endedAt, t0.addingTimeInterval(90))
    XCTAssertNil(b.resultText)
}

func testLateCompletionFillsSweptRun() {
    var assembler = AgentAssembler()
    let t0 = Date(timeIntervalSince1970: 1_784_692_800)
    assembler.feed([.spawned(toolUseId: "toolu_A", description: "Survey", type: "Explore", at: t0)])
    assembler.endAllRunning(at: t0.addingTimeInterval(90))
    assembler.feed([.completed(toolUseId: "toolu_A", resultText: "late report", at: t0.addingTimeInterval(120))])

    XCTAssertEqual(assembler.runs[0].resultText, "late report", "the body we were missing arrives")
    XCTAssertEqual(assembler.runs[0].endedAt, t0.addingTimeInterval(90), "sweep end stamp is kept")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter AgentEventsTests
```

Expected: both new tests FAIL to compile is NOT acceptable — `endAllRunning` doesn't exist yet, so the build fails with "value of type 'AgentAssembler' has no member 'endAllRunning'". That build error is this step's expected failure signal.

- [ ] **Step 3: Implement**

In `AgentAssembler`, replace the `.completed` case of `feed` and add `endAllRunning`:

```swift
case .completed(let id, let resultText, let at):
    guard let index = runs.firstIndex(where: { $0.id == id }) else { continue }
    // A real completion can land after a sweep already ended the run — keep the earlier
    // end stamp, but take the result body we were missing.
    if runs[index].endedAt == nil { runs[index].endedAt = at }
    if runs[index].resultText == nil { runs[index].resultText = resultText }
```

```swift
/// Turn-over backstop: the transcript never closed these runs out — end them now, so a
/// lost completion can't show a subagent as running forever.
public mutating func endAllRunning(at date: Date) {
    for index in runs.indices where runs[index].endedAt == nil {
        runs[index].endedAt = date
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter AgentEventsTests
```

Expected: ALL pass, including the existing `testAssemblerPairsSpawnsWithCompletions` (its single completion and unknown-id no-op still behave identically).

- [ ] **Step 5: Full suite, then commit**

```bash
swift test
git add Sources/LinkCKit/Usage/AgentEvents.swift Tests/LinkCKitTests/AgentEventsTests.swift
git commit -m "Agent assembler: turn-over sweep, late completions fill swept runs"
```

---

### Task 3: Wire the sweep — UsageTracker + AppCoordinator

**Files:**
- Modify: `Sources/LinkCKit/Usage/UsageTracker.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (the `handle(_:)` block around lines 144–148)
- Test: `Tests/LinkCKitTests/AgentEventsTests.swift`

**Interfaces:**
- Consumes: `AgentAssembler.endAllRunning(at:)` from Task 2; `SessionState` from `Core/Domain.swift`.
- Produces: `public func sweepAgents(_ sessionId: String, at date: Date = Date())` on `UsageTracker`; `AppCoordinator` calls it after `refreshSession` whenever the turn is over.

- [ ] **Step 1: Write the failing test**

Add a new test class at the bottom of `Tests/LinkCKitTests/AgentEventsTests.swift` (before the existing `AgeFormatTests`):

```swift
/// The tracker-level sweep: refresh reads the spawn from the transcript; the sweep then
/// ends anything the transcript never closed out.
final class AgentSweepTrackerTests: XCTestCase {
    @MainActor
    func testSweepEndsRunningAgents() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        let spawn = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_A","name":"Agent",\
        "input":{"description":"Survey","subagent_type":"Explore","prompt":"..."}}]}}
        """
        try (spawn + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "S1", transcriptPath: transcript.path)
        tracker.refreshSession("S1")
        XCTAssertTrue(tracker.sessionAgents("S1").contains(where: \.isRunning))

        tracker.sweepAgents("S1", at: Date(timeIntervalSince1970: 1_784_779_260))

        let runs = tracker.sessionAgents("S1")
        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(runs[0].isRunning)
        XCTAssertEqual(runs[0].endedAt, Date(timeIntervalSince1970: 1_784_779_260))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter AgentSweepTrackerTests
```

Expected: build error "value of type 'UsageTracker' has no member 'sweepAgents'" — that's the failure signal.

- [ ] **Step 3: Implement `sweepAgents` on UsageTracker**

In `Sources/LinkCKit/Usage/UsageTracker.swift`, after `sessionAgents(_:)`:

```swift
/// Backstop for lost completions: mark every still-running agent run ended. Called when
/// the session's turn is over — anything still "running" then is a phantom.
public func sweepAgents(_ sessionId: String, at date: Date = Date()) {
    guard var agents = agentAssemblers[sessionId] else { return }
    agents.endAllRunning(at: date)
    agentAssemblers[sessionId] = agents
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter AgentSweepTrackerTests
```

Expected: PASS.

- [ ] **Step 5: Wire into AppCoordinator**

In `Sources/LinkCKit/App/AppCoordinator.swift`, `handle(_:)`, replace:

```swift
// Every hook event names the session's transcript — bind it and refresh usage.
if let transcriptPath = event.transcriptPath, let tracker = usageTracker {
    tracker.bind(sessionId: session.id, transcriptPath: transcriptPath)
    tracker.refreshSession(session.id)
}
```

with:

```swift
// Every hook event names the session's transcript — bind it and refresh usage.
if let transcriptPath = event.transcriptPath, let tracker = usageTracker {
    tracker.bind(sessionId: session.id, transcriptPath: transcriptPath)
    tracker.refreshSession(session.id)
    // The refresh above applies any real completions first; only then does the
    // backstop end whatever the transcript never closed out.
    if turnIsOver(session.state) {
        tracker.sweepAgents(session.id)
    }
}
```

And add the helper below `handle(_:)`:

```swift
/// States in which no subagent can legitimately still be running. `.working`/`.starting`
/// are live; `.waitingPermission` pauses mid-turn — a sync subagent may be alive behind
/// the permission prompt, so it must not sweep.
private func turnIsOver(_ state: SessionState) -> Bool {
    switch state {
    case .ready, .waitingIdle, .finished, .error, .ended: return true
    case .starting, .working, .waitingPermission: return false
    }
}
```

- [ ] **Step 6: Full suite, then commit**

```bash
swift test
```

Expected: all tests pass (including `AppCoordinatorIntegrationTests`).

```bash
git add Sources/LinkCKit/Usage/UsageTracker.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AgentEventsTests.swift
git commit -m "Sweep phantom agent runs when the session's turn ends"
```

---

### Task 4: Extract SessionListColumn + selected-card treatment

**Files:**
- Create: `Sources/linkc/SessionList.swift`
- Modify: `Sources/linkc/PanelView.swift` (slim `HomeView`; delete moved structs)
- Modify: `Sources/linkc/Screens/TerminalsScreen.swift` (`TerminalCard` gains `isSelected`)
- Modify: `Sources/linkc/Theme.swift` (split tokens)

**Interfaces:**
- Consumes: `AppModel` (`sessions`, `shellRows`, `restorables`, `recentOutput`, `contextFill`, `visibleAgents`, `focus`, `stop`, shell actions), `Theme`, `SectionHeader`, `PreviewText`, `StatusDot` (all stay in their current files, same target).
- Produces:
  - `struct SessionListColumn: View` with `let model: AppModel`, `var selectedId: String? = nil`, `var horizontalPadding: CGFloat = 12` — Task 5 renders it at `.frame(width: Theme.sidebarWidth)` with `horizontalPadding: 0`.
  - `TerminalCard` and `HomeCard` accept `var isSelected: Bool = false`.
  - `Theme.splitBreakpoint: CGFloat = 600`, `Theme.sidebarWidth: CGFloat = 260`.

No unit harness covers these views — this task's gate is: clean build, full suite green, home renders identically (verified in Task 7).

- [ ] **Step 1: Add the Theme tokens**

In `Sources/linkc/Theme.swift`, after the `dockInset` declaration:

```swift
// The sidebar split: with a terminal open and at least `splitBreakpoint` of pane width,
// the home list rides beside the terminal as a fixed column instead of the mini-tab strip.
static let splitBreakpoint: CGFloat = 600
static let sidebarWidth: CGFloat = 260
```

- [ ] **Step 2: Create `Sources/linkc/SessionList.swift`**

Move — verbatim except where noted — `HomeView`'s list internals plus `TerminalsSection`, `EarlierSection`, `RestorableRow`, and `HomeCard` out of `PanelView.swift` into this new file. Changes from verbatim: the moved `HomeView.sessionList/liveSections/rows` become `SessionListColumn` with the `selectedId`/`horizontalPadding` parameters; `HomeCard` and `TerminalsSection` gain selection parameters. Full file:

```swift
import SwiftUI
import AppKit
import LinkCKit

/// The scrolling session/terminal/earlier column — the whole of home's list, reusable as
/// the sidebar beside an open terminal. In sidebar mode `selectedId` highlights the open
/// item's card and `horizontalPadding` lets the caller own the gutters.
struct SessionListColumn: View {
    let model: AppModel
    var selectedId: String? = nil
    var horizontalPadding: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One row of the sectioned overview: a section header or a live session card. Cards keep a
    /// stable id (`session.id`) so a state change reorders the flat list and SwiftUI *moves* the
    /// card to its new section rather than recreating it — that move is what the spring animates.
    private enum Row: Identifiable {
        case header(String)
        case card(Session)

        var id: String {
            switch self {
            case .header(let title): return "header-\(title)"
            case .card(let session): return session.id
            }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                // Live cards refresh their terminal previews about once a second — and only while
                // this column is on screen, since it exists only then. Restorable cards have no
                // live output, so they sit outside the timeline.
                if !model.sessions.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        liveSections
                    }
                }
                // Dev terminals: same 1s preview cadence as sessions, quieter presence.
                if !model.shellRows.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        TerminalsSection(model: model, selectedId: selectedId)
                    }
                }
                if !model.restorables.isEmpty {
                    EarlierSection(model: model)
                }
            }
            .readingColumn()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
        }
    }

    /// The live sessions as a priority queue: NEEDS YOU → WORKING → IDLE, each a stable row in one
    /// flat list so cards glide between sections on a state change. Reduce Motion drops the spring.
    @MainActor @ViewBuilder private var liveSections: some View {
        let rows = self.rows
        VStack(spacing: 6) {
            ForEach(rows) { row in
                switch row {
                case .header(let title):
                    SectionHeader(title: title)
                        .padding(.top, 6)
                        .transition(.opacity)
                case .card(let session):
                    HomeCard(
                        session: session,
                        preview: model.recentOutput(session.id, lines: 3),
                        contextFill: model.contextFill(session.id),
                        agents: model.visibleAgents(session.id),
                        isSelected: session.id == selectedId,
                        onOpen: { model.focus(session.id) },
                        onClose: { model.stop(session.id) }
                    )
                    // Cards materialize: a soft settle-in rather than a pop. Reduce Motion
                    // keeps only the fade.
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: rows.map(\.id))
    }

    /// Group live sessions by urgency bucket, in priority order, preserving each session's relative
    /// order within its bucket. Empty buckets are dropped; headers are shown only when more than one
    /// bucket is present (a lone group needs no label).
    @MainActor private var rows: [Row] {
        let sessions = model.sessions
        let groups: [(String, [Session])] = [
            ("NEEDS YOU", sessions.filter { $0.state.bucket == .needsYou }),
            ("WORKING", sessions.filter { $0.state.bucket == .active }),
            ("IDLE", sessions.filter { $0.state.bucket == .idle }),
        ].filter { !$0.1.isEmpty }

        let showHeaders = groups.count > 1
        return groups.flatMap { title, group -> [Row] in
            (showHeaders ? [Row.header(title)] : []) + group.map(Row.card)
        }
    }
}

// MARK: - Terminals (dev shells)

/// The dev-terminal section — plain shells beside the claude sessions, deliberately
/// quieter (no urgency states, no pulse).
struct TerminalsSection: View {
    let model: AppModel
    var selectedId: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            SectionHeader(title: "TERMINALS")
                .padding(.top, 6)
            ForEach(model.shellRows) { row in
                TerminalCard(
                    row: row,
                    preview: model.recentOutput(row.id, lines: 3),
                    isSelected: row.id == selectedId,
                    onOpen: { model.focus(row.id) },
                    onStop: { model.stopShell(row.id) },
                    onRelaunch: { model.relaunchShell(row) },
                    onDismiss: { model.dismissShell(row.id) }
                )
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: model.shellRows.map(\.id))
    }
}

// MARK: - Earlier (restorable sessions)

/// Previous sessions from an earlier run, shown below the live cards: a quiet section header —
/// with an inline "Restore all" only when there are 2+ to restore — then one dim row per
/// restorable session.
struct EarlierSection: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("EARLIER")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                // "Restore all" earns its place only when there is more than one thing to
                // restore; inline with the label so it never stacks over the rows' own
                // Restore buttons.
                if model.restorables.count > 1 {
                    Text("·")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Button(action: { model.restoreAll() }) {
                        Text("Restore all")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Restore every previous session")
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            ForEach(model.restorables) { session in
                RestorableRow(
                    session: session,
                    onRestore: { model.restore(session) },
                    onDismiss: { model.dismiss(session) }
                )
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        // Restored/dismissed rows leave with the section spring so the rest glide up.
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: model.restorables.map(\.id))
    }
}

/// One previous session as a quiet row — transparent until hovered, when a soft wash and its
/// dismiss x appear. History shouldn't compete with live cards: no fill, no preview, just an
/// ended-grey dot, the title and folder, when it ended, and a plain Restore action.
private struct RestorableRow: View {
    let session: RestorableSession
    let onRestore: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: .ended)
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let endedText = session.endedLabel(now: Date()) {
                Text(endedText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }

            Spacer(minLength: 8)

            Button(action: onRestore) {
                Text("Restore")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Resume this session")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.hover : Color.clear)
        )
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A single session card: a soft fill (a faint coral wash when it needs you), a status · title ·
/// path header line, and a dim monospaced preview of the last few terminal rows aligned under the
/// title. The state is the dot; words appear only when the session needs you. The whole card is
/// the tap target. `isSelected` (the sidebar's open item) brightens the plane and hangs an
/// accent hairline off the leading edge.
struct HomeCard: View {
    let session: Session
    let preview: String
    /// 0…1 context-window fill for the hairline along the bottom edge; nil hides it.
    let contextFill: Double?
    /// Subagents worth showing: running ones plus the recently finished.
    let agents: [AgentRun]
    var isSelected: Bool = false
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(state: session.state)
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                // State text only when there's something to act on — the dot carries the rest.
                if session.state.bucket == .needsYou {
                    // Time-in-state: a 10-second wait and a 20-minute wait are different
                    // situations — say which this is.
                    Text("\(statusLabel(session.state)) · \(AgeFormat.compact(from: session.stateChangedAt))")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.statusColor(session.state))
                        .fixedSize()
                }
                if agents.contains(where: \.isRunning) {
                    AgentChip(count: agents.count { $0.isRunning })
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Stop session")
            }
            PreviewText(text: preview)
            // The agent lane: the card grows quietly while the session fans out.
            if !agents.isEmpty {
                VStack(spacing: 2) {
                    ForEach(agents) { AgentLine(agent: $0) }
                }
                .padding(.top, 4)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Context fill as a 2pt hairline flush to the bottom edge — quiet white until the
        // conversation nears auto-compact, then the warning gold. Clipped to the card shape
        // before the plane goes on, so the shadow isn't clipped with it.
        .overlay(alignment: .bottomLeading) {
            if let contextFill {
                GeometryReader { geo in
                    Rectangle()
                        .fill(contextFill > 0.75 ? Theme.contextWarn : Color.white.opacity(0.25))
                        .frame(width: geo.size.width * contextFill, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .planeCard(needsYou: session.state.bucket == .needsYou, hovering: hovering || isSelected)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: 2)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help("Open \(session.title)")
    }
}

/// Shared status copy for a card's needs-you label.
func statusLabel(_ state: SessionState) -> String {
    switch state {
    case .starting: return "starting"
    case .ready: return "ready"
    case .working: return "working"
    case .waitingPermission: return "needs permission"
    case .waitingIdle: return "waiting for input"
    case .finished: return "finished"
    case .error: return "error"
    case .ended: return "ended"
    }
}
```

- [ ] **Step 3: Slim `PanelView.swift`**

Delete from `Sources/linkc/PanelView.swift`: the private structs `TerminalsSection`, `EarlierSection`, `RestorableRow`, `HomeCard`, the `private func statusLabel(_:)` at the bottom (moved above, now internal), and `HomeView`'s `sessionList` / `liveSections` / `rows` / `Row`. Keep `SectionHeader`, `PreviewText`, and everything else. Replace `HomeView` with:

```swift
/// The overview shown when no session is selected: the shared session-list column with the
/// plan-usage footer pinned beneath it. Tapping a card opens that session's full terminal.
private struct HomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SessionListColumn(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The one place plan usage appears: a quiet footer line pinned under the list.
            if let label = model.windowUsageLabel, model.preferences.showsUsageFooter {
                HStack {
                    Text(label)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Note: `HomeView`'s old `@Environment(\.accessibilityReduceMotion)` moves out with the list (the slimmed `HomeView` no longer needs it). The scroll padding changes shape slightly: the old `sessionList` used `.padding(.vertical, 12)` on home; `SessionListColumn` keeps that.

- [ ] **Step 4: `TerminalCard` gains `isSelected`**

In `Sources/linkc/Screens/TerminalsScreen.swift`, add the property to `TerminalCard` (after `preview`):

```swift
var isSelected: Bool = false
```

change the `planeCard` line and add the selection hairline after it:

```swift
.planeCard(hovering: (hovering && isRunning) || isSelected)
.overlay(alignment: .leading) {
    if isSelected {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent.opacity(0.7))
            .frame(width: 2)
            .padding(.vertical, 10)
            .padding(.leading, 1)
    }
}
```

and update the doc comment's card list to mention the sidebar's selected state. The `TerminalsScreen` call site is unchanged (default `false`).

- [ ] **Step 5: Build + full suite**

```bash
swift build && swift test
```

Expected: clean build, all tests pass. Home behavior is unchanged (nothing passes `selectedId` yet).

- [ ] **Step 6: Commit**

```bash
git add Sources/linkc/SessionList.swift Sources/linkc/PanelView.swift Sources/linkc/Screens/TerminalsScreen.swift Sources/linkc/Theme.swift
git commit -m "Extract SessionListColumn with selected-card treatment"
```

---

### Task 5: TerminalHero split layout

**Files:**
- Modify: `Sources/linkc/PanelView.swift` (`TerminalHero` only)

**Interfaces:**
- Consumes: `SessionListColumn(model:selectedId:horizontalPadding:)`, `Theme.splitBreakpoint`, `Theme.sidebarWidth` from Task 4; existing `SessionStrip`, `AgentStrip`, `AgentReaderView`, `TerminalContainer`.
- Produces: no new API — `TerminalHero` internals only.

- [ ] **Step 1: Rewrite `TerminalHero`**

Replace the whole `private struct TerminalHero` in `Sources/linkc/PanelView.swift` with:

```swift
/// The open terminal, split beside the session list when the pane is wide enough. Narrow
/// panes keep the original full-bleed terminal with the mini-tab strip; the split's sidebar
/// replaces the strip entirely. The agent reader swaps only the terminal side in the split
/// (the whole pane when narrow).
private struct TerminalHero: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An agent opened for reading — replaces the terminal until dismissed.
    @State private var readerAgent: AgentRun?

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= Theme.splitBreakpoint
            HStack(alignment: .top, spacing: 12) {
                if split {
                    SessionListColumn(model: model, selectedId: model.selectedId, horizontalPadding: 0)
                        .frame(width: Theme.sidebarWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                rightPane(split: split)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .onChange(of: model.selectedId, initial: true) { _, _ in
            readerAgent = nil
            styleTerminal(model.selectedTerminal)
        }
    }

    /// The terminal column (or the agent reader in its place). In the split the sidebar is
    /// the switcher, so the mini-tab strip renders only when narrow.
    @ViewBuilder private func rightPane(split: Bool) -> some View {
        ZStack {
            if let readerAgent {
                AgentReaderView(agent: currentAgent(readerAgent)) { self.readerAgent = nil }
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    // Sibling sessions as mini-tabs — switch without going home.
                    if !split, model.showsSessionStrip {
                        SessionStrip(sessions: model.sessions, selectedId: model.selectedId) {
                            model.focus($0)
                        }
                        .transition(.opacity)
                    }
                    // Live subagents ride above the terminal; TimelineView keeps their
                    // ages/spinners honest while the strip is visible.
                    if let id = model.selectedId, !model.visibleAgents(id).isEmpty {
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            AgentStrip(agents: model.visibleAgents(id)) { readerAgent = $0 }
                        }
                        .transition(.opacity)
                    }
                    ZStack {
                        TerminalContainer(session: model.selectedTerminal)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                        if model.selectedTerminal == nil {
                            Text("Select a session")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.viewSwap, value: readerAgent?.id)
    }

    /// Re-resolve the opened agent so a completion arriving mid-read fills the body in.
    private func currentAgent(_ agent: AgentRun) -> AgentRun {
        guard let id = model.selectedId else { return agent }
        return model.visibleAgents(id).first { $0.id == agent.id } ?? agent
    }

    /// Restyle the live terminal to the tokens from the panel side (the Terminal module is left
    /// untouched): SF Mono at 12.5 and a genuinely translucent background, so the glass reads
    /// through the terminal itself instead of framing an opaque slab. SwiftTerm keeps the
    /// NSColor's alpha for every default-background cell fill; the one opaque remnant is the
    /// view's CALayer background, which `setupOptions()` re-stamps on font changes — so the
    /// font must be set first and the layer cleared last.
    private func styleTerminal(_ session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.30)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
```

- [ ] **Step 2: Build + full suite**

```bash
swift build && swift test
```

Expected: clean build, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/linkc/PanelView.swift
git commit -m "Split terminal pane: session list rides beside the open terminal"
```

---

### Task 6: Widen the panel for the split on selection

**Files:**
- Modify: `Sources/linkc/StatusPanelController.swift`

**Interfaces:**
- Consumes: `Theme.splitBreakpoint` (same target), existing `clampToScreen(_:)`, `selectionDidChange(to:)`, `panelSize()`.
- Produces: no new API — controller internals only.

- [ ] **Step 1: Implement widen-on-selection**

In `Sources/linkc/StatusPanelController.swift`:

1a. Add a constant next to `panelMinSize`:

```swift
/// Comfortable width for the split (sidebar + terminal). Selection grows the panel to
/// this when it's too narrow for the split; it never shrinks the panel.
private let splitTargetWidth: CGFloat = 760
```

1b. Update `panelSize()` so a present-while-selected opens wide enough (replace the return):

```swift
private func panelSize() -> CGSize {
    let defaultWidth: CGFloat = 480
    let defaultHeight: CGFloat = 300
    let w = UserDefaults.standard.double(forKey: SizeKey.width)
    let h = UserDefaults.standard.double(forKey: SizeKey.height)
    var width = max(w > 0 ? w : defaultWidth, panelMinSize.width)
    // With a terminal open the pane splits into sidebar + terminal — a fresh present
    // starts wide enough for it. A user-dragged size wins when it's already wider.
    if model.selectedId != nil, width < splitTargetWidth { width = splitTargetWidth }
    return CGSize(
        width: width,
        height: max(h > 0 ? h : defaultHeight, panelMinSize.height)
    )
}
```

1c. Update `selectionDidChange(to:)` to widen a visible panel, and add the helper:

```swift
/// A session was selected. If the panel is open, raise it + focus its terminal; if hidden (a
/// programmatic focus, e.g. a notification click), open it to reveal the session. Either way,
/// make sure the panel is wide enough for the sidebar split.
private func selectionDidChange(to id: String?) {
    guard id != nil else { return }
    if panel.isVisible {
        panel.makeKeyAndOrderFront(nil)   // raise on programmatic focus
        focusTerminalIfNeeded()
        ensureSplitWidth()
    } else {
        present(activating: true)         // panelSize() already accounts for the selection
    }
}

/// Grow a too-narrow panel leftward (top-right stays anchored) so the split fits. Only
/// ever widens — and only below the split's breakpoint, so a user who deliberately keeps
/// the panel between the breakpoint and the target is left alone.
private func ensureSplitWidth() {
    guard panel.frame.width < Theme.splitBreakpoint else { return }
    var frame = panel.frame
    frame.origin.x = frame.maxX - splitTargetWidth
    frame.size.width = splitTargetWidth
    frame = clampToScreen(frame)
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(frame, display: true)
    }
}
```

(The stale "Widths: compact when nothing is selected…" comment block above `panelMinSize` now describes real behavior again — rewrite it to: `/// Width: the user's persisted size, widened for the sidebar split while a session is selected. Height derives from the persisted size too.`)

- [ ] **Step 2: Build + full suite**

```bash
swift build && swift test
```

Expected: clean build, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/linkc/StatusPanelController.swift
git commit -m "Widen the panel for the sidebar split when a session is selected"
```

---

### Task 7: End-to-end verification

**Files:** none (verification only; fix regressions where found).

- [ ] **Step 1: Full suite + release build**

```bash
swift test && swift build
```

Expected: everything green.

- [ ] **Step 2: Run the app and verify visually**

```bash
./build-app.sh
```

(then launch the built app — see the script's output for the .app path; `open <path>` it.)

Verify each, resizing the panel by its edges:

1. Empty state, home overview, and dock screens look unchanged.
2. Open a session → panel widens to ~760; sidebar shows the session list beside the live terminal; the open card is brighter with a leading accent hairline.
3. Tap another card in the sidebar → terminal switches in place; highlight follows.
4. Start a dev terminal → it appears in the sidebar's TERMINALS section; selecting it highlights it.
5. Drag the panel narrower than ~600 → sidebar folds away, mini-tab strip returns above the terminal.
6. With a subagent running, open its reader from the agent strip → in split mode the reader replaces only the terminal side; the sidebar stays.
7. Let a session with subagents finish its turn → no agent chip/lane stays "running" after the turn ends.
8. Capture screenshots of home, the split, and the narrow fallback for the PR.

- [ ] **Step 3: Cleanup pass**

Confirm no debug artifacts (prints, commented-out code, scratch files) were left behind:

```bash
git status && git diff main --stat
```

- [ ] **Step 4: Done — hand off**

Implementation complete on `sessions-sidebar`. Use superpowers:finishing-a-development-branch (merge vs PR decision belongs to the user).
