# Injected Messages Submit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every message linkC types into an agent's terminal is submitted, without the user pressing
Enter. That covers task notices, "done (unverified)", peer notes and `/model` switches.

**Architecture:**
- `TerminalSession.sendInput` becomes a small, testable plan of steps. Its one-line path sends a
  single Return after the same 300 ms settle the paste path uses.
- `dispatchMessages` delivers everything queued for one session as one injection.
- A per-session gap keeps a task brief and a message from landing in the same moment.

**Tech Stack:** Swift 6, macOS 14, SwiftTerm, XCTest.

## Why (the investigation, 2026-09-24)

Jacob had to press Enter on two notices sitting in a Claude session's input:

```
[linkC task D9634853] Codex turn ended without a report. Task remains started; linkc_get_task(…) or linkc_cancel_task(…).
[linkC task D9634853] done (unverified)
```

Both were queued while the Claude session worked. The relay delivered both in one tick when the
session went idle.

The problem was replayed against the real Claude Code 2.1.281 (`claude --model haiku` in tmux; script
`scratchpad/repro_enter.py`):

| Replay | Result |
|---|---|
| Today's path, two notices back to back (each: text, Return, Return; then Return and Return 75 ms later) | Not submitted, both in the input |
| Today's path, one notice | **Also not submitted** |
| Typed text, then one Return 300 ms later | Submitted |
| Both notices as one bracketed paste, then one Return 300 ms later | Submitted, both in one prompt |

**Root cause:** Claude Code treats a fast burst of input as a paste. The typed path's immediate
Return, and the second one 75 ms later, both fall inside that window and are absorbed. Multi-line
briefs already wait 300 ms (`pasteSettleMilliseconds`) and work.

Two messages in one tick make it worse. Even with the timing fixed, typed messages would concatenate
on one line, and the second Return would land mid-turn.

The 2026-09-18 investigation found delivery working. Claude Code has changed since; don't trust
that note.

## Global Constraints

- Swift 6 / macOS 14. No new dependencies.
- TDD: each test is seen failing on an assertion before its fix. Record the red and green lines.
- **Fail loud:** a dropped injection is logged, never silent. An injection is always recorded in
  `recentlyInjectedTexts` (the limit detector depends on it).
- **Commits:**
  - One-line `fix(relay): …` messages.
  - Stage by name.
  - Never touch the untracked `system-map.json`.
  - No "claude" in any case in messages.
  - No trailers of any kind.
- **Verify:**
  - `swift build 2>&1 | tail -3` is clean;
  - `swift build 2>&1 | grep -i warning` prints nothing;
  - `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` shows 0 failures. Record the
    baseline at the start.

---

### Task 1: One Return, after the settle

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift`
- Test: `Tests/LinkCKitTests/TerminalSessionTests.swift`

**Interfaces:**

```swift
/// What `sendInput` writes, in order. Pure, so the timing rule is tested without a terminal.
enum InputStep: Equatable { case text(String), pasteStart, pasteEnd, wait(milliseconds: Int), submit }

static func inputPlan(for text: String, negotiatedPaste: Bool) -> [InputStep]
```

**Rules:**
- Trailing `\n` and `\r` are trimmed, as now.
- Empty text gives `[.submit]`: a bare Return, as now.
- **One-line text** gives `[.text(t), .wait(pasteSettleMilliseconds), .submit]`. There is no
  immediate Return, no `insertNewline`, and no second Return.
- **Multi-line text with paste negotiated** gives
  `[.pasteStart, .text(t), .pasteEnd, .wait(pasteSettleMilliseconds), .submit]`.
- **Multi-line text without paste** (a raw shell) gives `[.text(t), .submit]`. The shell submits
  line by line, which is today's behaviour; keep its log line.
- `sendInput` executes the plan:
  - `.submit` sends `"\r"`;
  - `.wait` is a `Task.sleep` inside one `@MainActor` task that runs the rest of the plan in order;
  - before each send after a wait, re-check `liveness` and log if the child has died.
- Delete the old `doCommand(insertNewline)` path and the 75 ms double send, along with their
  comments. Update the `pasteSettleMilliseconds` doc: it now applies to every submit that follows
  text, as measured against Claude Code 2.1.281.

- [ ] **Step 1: Write the failing tests.**

```swift
func testAOneLineMessageWaitsForTheSettleThenSubmitsOnce() {
    XCTAssertEqual(TerminalSession.inputPlan(for: "[linkC task X] done (unverified)\n", negotiatedPaste: true),
                   [.text("[linkC task X] done (unverified)"), .wait(milliseconds: TerminalSession.pasteSettleMilliseconds), .submit])
    XCTAssertEqual(TerminalSession.inputPlan(for: "ls", negotiatedPaste: false),
                   [.text("ls"), .wait(milliseconds: TerminalSession.pasteSettleMilliseconds), .submit])
}

func testAMultiLineMessagePastesThenSubmitsOnceAfterTheSettle() {
    XCTAssertEqual(TerminalSession.inputPlan(for: "a\nb", negotiatedPaste: true),
                   [.pasteStart, .text("a\nb"), .pasteEnd, .wait(milliseconds: TerminalSession.pasteSettleMilliseconds), .submit])
}

func testARawShellGetsMultiLineTextAsIs() {
    XCTAssertEqual(TerminalSession.inputPlan(for: "a\nb", negotiatedPaste: false), [.text("a\nb"), .submit])
}

func testEveryPlanSubmitsExactlyOnce() {
    for (text, paste) in [("x", true), ("x", false), ("a\nb", true), ("a\nb", false), ("", true)] {
        XCTAssertEqual(TerminalSession.inputPlan(for: text, negotiatedPaste: paste).filter { $0 == .submit }.count, 1, "\(text) \(paste)")
    }
}
```

  Also check an existing mock-terminal test (the `cat` agent in `AppCoordinatorRelayTests`) still
  sees the injected text. Then add one that waits past the settle and sees the Return echoed exactly
  once, if the mock's output makes that observable.

- [ ] **Steps 2–5:** red, implement, green, then commit: `fix(relay): typed messages submit with one Return after the settle`

---

### Task 2: One injection per session, then a gap

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`dispatchTasks`, `dispatchMessages`) and
  `Sources/LinkCKit/App/AppCoordinator.swift` (`recordInjection`, a per-session last-injection time).
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Rules:**
- **The gap.**
  - `recordInjection` also stamps `lastInjectionAt[sessionId] = now()`.
  - A session is a delivery target only when `now() - lastInjectionAt >= injectionGap`. That is a
    new `static let injectionGap: TimeInterval = 2`, overridable in `init` like `deliverySettle`.
  - This applies in both `dispatchTasks` (the idle-candidate filter) and `dispatchMessages` (the
    target check).
  - A message or task that isn't delivered stays queued for a later tick, never dropped. Log
    once per tick that it waited.
  - Clear the stamp where `injectedText` is cleared for an ended session.
- **Batching in `dispatchMessages`.**
  - Work out each queued message's target as today, then group the deliverable ones by target
    session, in queue order.
  - Per session, per tick, send **one** injection:
    - a `.command` (e.g. `/model …`) or a legacy `.task` brief is always sent alone. If the group's
      first deliverable message is one of these, send only it; otherwise stop the batch at the first
      one, which waits for the next tick.
    - Otherwise, batch every consecutive `.completion`/`.peerNote` message: mark each delivered, as
      today, then send their prompts joined with `"\n"` as one `sendInput`. A multi-line batch takes
      the paste path from Task 1.
  - Record each batched message's text separately with `recordInjection`, because the limit
    detector suppresses echoes entry by entry. Stamp the gap once.
  - A message whose mark fails for a reason other than a lock timeout is skipped, as now, and is not
    in the batch.
  - A lock timeout ends the tick, as now.
- The `/model` re-derivation and the `.task` state update keep their current behaviour for the
  message they apply to.

- [ ] **Step 1: Write the failing tests** (use the file's `makeCoordinator(now:)` clock, the mock
  agent, `waitForPasteReady` and `recentlyInjectedTexts`):

```swift
@MainActor
func testTwoNoticesForOneSessionGoOutAsOneInjection() async throws {
    // A delegator Claude session, idle; two completion messages queued for it (echo a task's
    // turn-end notice and its "done (unverified)" line, as the relay does).
    // One dispatchMessages tick → exactly one sendInput reaching the terminal, containing both lines,
    // in queue order; both rows marked delivered; recentlyInjectedTexts has both texts as two entries.
}

@MainActor
func testATaskBriefAndAMessageForOneSessionNeverLandTogether() async throws {
    // Same tick: dispatchTasks injects a brief into the idle session; dispatchMessages must leave a
    // queued completion for that session queued. Advance the test clock by injectionGap → the next
    // tick delivers it.
}

@MainActor
func testACommandIsNeverBatched() async throws {
    // Queue a peer note, then "/model x", then another peer note, all for one session. Tick 1 sends
    // the first peer note alone (the batch stops at the command); after the gap, tick 2 sends
    // "/model x" alone; after another gap, tick 3 sends the last note.
}
```

  Fill the bodies in with the file's existing patterns. The comments state exactly what to assert.

- [ ] **Steps 2–5:** red, implement, green, then commit: `fix(relay): one injection per session per tick, batched, with a gap before the next`

---

### Task 3: Prove it against the real CLI

This is not code: the controller does it, or the implementer if tmux and the Claude CLI are
available.
- Re-run `repro_enter.py`, adapted to replay the *new* sequence: text, 300 ms, then one Return;
  and a two-notice batch as one paste, 300 ms, then one Return. Use `claude --model haiku` in a
  trusted folder, and show both submitted.
- If Codex is available, run the same one-line replay against `codex` in a trusted folder and report
  it. Skip it if the trust dialog blocks, and say so.
- In the running app, after the build, delegate a small task from Claude to Codex. Watch the
  completion notice arrive in Claude and submit on its own.
