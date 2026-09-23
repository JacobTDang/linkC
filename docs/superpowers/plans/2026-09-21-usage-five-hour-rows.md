# Usage Rows in One Shape — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude's and Codex's Usage rows both show the live 5-hour percentage, or "session/weekly limit hit", with Claude's figures read from its status line.

**Architecture:** linkC adds a silent `statusLine` to each Claude session's settings; it POSTs Claude's status JSON to the existing hook server as event `status_line`. The server decodes `rate_limits` into an `AgentUsage` and hands it to the coordinator, which keeps the newest reading. `UsageRows.build` applies one rule table to both agents. Because a status line hides Claude's "esc to interrupt" footer hint, `TerminalPreview.liveActivity` learns to read Claude's spinner row instead.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, macOS 14, XCTest, Network.framework (existing `HookServer`).

**Spec:** `docs/superpowers/specs/2026-09-21-usage-five-hour-rows-design.md`

## Global Constraints

- No new dependencies or packages.
- Test-driven: write the failing test first, run it and see it fail, then implement. Mock data only in tests.
- Fail loud: no swallowed errors. A status-line body that is not valid JSON is logged with `NSLog`, never silently dropped.
- The status line command, exactly: `curl -s -m 2 -X POST -H 'X-LinkC-Token: <token>' -H 'X-LinkC-Event: status_line' --data-binary @- http://127.0.0.1:<port>/hook >/dev/null`
- The event header value is exactly `status_line` (`HookServer.statusLineEvent`).
- Window labels: `five_hour` → `"5h"`, `seven_day` → `"7d"`.
- Row texts, exactly: `37% · resets 2h` · `session limit hit · resets 2h` · `weekly limit hit · resets 3d` · `limit hit · retry 15m`. No token counts in any row.
- Headline: `limit hit` when any row shows a hit (a window hit or a detector cap); otherwise the highest live figure percentage (`68%`); nil when none.
- Coral: a hit row is coral; a normal row is coral only when its shown figure is live and rounds to ≥ 80. A stale row is never coral. A weekly window near its limit (but not full) appears in help only.
- "Full" means the rounded percentage is ≥ 100, and only a live window (fresh reading, reset not passed) can be full.
- Reset times: `AgeFormat.compact` under a day ("15m", "2h"), `AgeFormat.longSpan` from a day on ("1d", "3d"). The detector cap's retry keeps `AgeFormat.compact`.
- Reasons, exactly: Claude with no reading → `no reading yet — a Claude session reports after its first reply`; Claude with the user's own status line → `your own status line is configured — linkC can't read Claude's usage`; Codex with no reading → `not read yet` (unchanged).
- linkC never replaces a status line the user set in `~/.claude/settings.json`, the project's `.claude/settings.json`, or its `.claude/settings.local.json`.
- Commits: author is the repo's configured git user. Commit messages must NOT contain the word "claude" in any case, and carry no `Co-Authored-By`, `Generated with`, or other trailers. Before reporting, run `git log -1 --format=%B | grep -ic claude` and confirm it prints `0`.
- Before committing, run `git diff --cached --stat` and confirm every file you changed is staged.
- Run tests with `swift test --filter <TestClass>`; the full suite with `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`. Baseline: 985 tests, 5 skipped, 0 failures.

---

### Task 1: Decode Claude's rate limits

**Files:**
- Create: `Sources/LinkCKit/Usage/ClaudeRateLimits.swift`
- Test: `Tests/LinkCKitTests/ClaudeRateLimitsTests.swift`

**Interfaces:**
- Consumes: `AgentUsage`, `UsageWindow` (`Sources/LinkCKit/Usage/AgentUsage.swift`).
- Produces:
  - `ClaudeRateLimits.decode(_ body: Data, receivedAt: Date) throws -> AgentUsage?`
  - `ClaudeRateLimits.newer(_ current: AgentUsage?, _ incoming: AgentUsage) -> AgentUsage`
  - `ClaudeRateLimits.usage(reading: AgentUsage?, userOwnsStatusLine: Bool) -> AgentUsage?`
  - `ClaudeRateLimits.ownStatusLineReason: String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/ClaudeRateLimitsTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class ClaudeRateLimitsTests: XCTestCase {
    private let arrived = Date(timeIntervalSince1970: 1_789_970_000)

    /// The example from Claude Code's status-line docs.
    func testTheDocsExampleDecodesToBothWindows() throws {
        let body = Data(#"""
        {"session_id": "abc", "rate_limits": {
          "five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
          "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600}}}
        """#.utf8)
        let usage = try XCTUnwrap(ClaudeRateLimits.decode(body, receivedAt: arrived))

        XCTAssertEqual(usage.agent, .claude)
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(usage.windows[0].usedPercent, 23.5)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(usage.windows[1].usedPercent, 41.2)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertNil(usage.windows[0].tokens)
        XCTAssertEqual(usage.observedAt, arrived)
        XCTAssertNil(usage.planType)
        XCTAssertNil(usage.unavailableReason)
    }

    /// A body captured from Claude Code 2.1.278: whole-number percentages, many other fields.
    func testACapturedBodyWithOtherFieldsDecodes() throws {
        let body = Data(#"""
        {"session_id": "7a21", "cwd": "/tmp/work", "model": {"id": "x", "display_name": "Opus"},
         "context_window": {"used_percentage": 3}, "cost": {"total_cost_usd": 0.1},
         "rate_limits": {"five_hour": {"used_percentage": 66, "resets_at": 1789980000},
                         "seven_day": {"used_percentage": 92, "resets_at": 1790017200}}}
        """#.utf8)
        let usage = try XCTUnwrap(ClaudeRateLimits.decode(body, receivedAt: arrived))
        XCTAssertEqual(usage.windows.map(\.usedPercent), [66, 92])
    }

    func testOneWindowAloneDecodes() throws {
        let body = Data(#"{"rate_limits": {"seven_day": {"used_percentage": 12, "resets_at": 1790017200}}}"#.utf8)
        let usage = try XCTUnwrap(ClaudeRateLimits.decode(body, receivedAt: arrived))
        XCTAssertEqual(usage.windows.map(\.label), ["7d"])
    }

    /// API-key sessions, and every session before its first reply, report no limits at all.
    func testABodyWithNoWindowsIsNoReading() throws {
        for json in [#"{"session_id": "abc"}"#, #"{"rate_limits": null}"#, #"{"rate_limits": {}}"#] {
            XCTAssertNil(try ClaudeRateLimits.decode(Data(json.utf8), receivedAt: arrived), json)
        }
    }

    func testABodyThatIsNotJSONThrows() {
        XCTAssertThrowsError(try ClaudeRateLimits.decode(Data("not json".utf8), receivedAt: arrived))
    }

    func testTheLaterReadingWinsWhateverOrderTheyArriveIn() {
        let early = AgentUsage(agent: .claude, windows: [], planType: nil, observedAt: arrived, unavailableReason: nil)
        let late = AgentUsage(agent: .claude, windows: [], planType: nil,
                              observedAt: arrived.addingTimeInterval(5), unavailableReason: nil)
        XCTAssertEqual(ClaudeRateLimits.newer(nil, early), early)
        XCTAssertEqual(ClaudeRateLimits.newer(early, late), late)
        XCTAssertEqual(ClaudeRateLimits.newer(late, early), late, "an older reading landing last must not win")
    }

    func testUsagePrefersTheReadingThenTheReasonNoneCanCome() {
        let reading = AgentUsage(agent: .claude, windows: [], planType: nil, observedAt: arrived, unavailableReason: nil)
        XCTAssertEqual(ClaudeRateLimits.usage(reading: reading, userOwnsStatusLine: true), reading)
        XCTAssertEqual(
            ClaudeRateLimits.usage(reading: nil, userOwnsStatusLine: true)?.unavailableReason,
            "your own status line is configured — linkC can't read Claude's usage")
        XCTAssertNil(ClaudeRateLimits.usage(reading: nil, userOwnsStatusLine: false))
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter ClaudeRateLimitsTests`
Expected: build failure — `cannot find 'ClaudeRateLimits' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Usage/ClaudeRateLimits.swift`:

```swift
import Foundation

/// Claude Code's own rate-limit figures, as its status-line command receives them on stdin:
/// `rate_limits.five_hour` and `rate_limits.seven_day`, each `{used_percentage, resets_at}`
/// (percent 0–100, Unix seconds). Present only on Pro and Max plans and only after a session's
/// first reply; either window may be missing. Every other status-line field is ignored.
public enum ClaudeRateLimits {
    /// Why Claude's row has no figure when a status line of the user's own is configured: linkC
    /// never replaces it, so it never hears Claude's figures.
    public static let ownStatusLineReason = "your own status line is configured — linkC can't read Claude's usage"

    /// The windows in a status-line body, as a reading taken at `receivedAt`. nil when the body
    /// names neither window. Throws when the body is not the JSON Claude Code sends.
    public static func decode(_ body: Data, receivedAt: Date) throws -> AgentUsage? {
        let payload = try JSONDecoder().decode(Payload.self, from: body)
        guard let limits = payload.rateLimits else { return nil }
        var windows: [UsageWindow] = []
        if let window = limits.fiveHour { windows.append(window.usageWindow(label: "5h")) }
        if let window = limits.sevenDay { windows.append(window.usageWindow(label: "7d")) }
        guard !windows.isEmpty else { return nil }
        return AgentUsage(agent: .claude, windows: windows, planType: nil, observedAt: receivedAt, unavailableReason: nil)
    }

    /// The later of two readings. Readings hop to the main actor in separate tasks, so one taken
    /// earlier can land after one taken later.
    public static func newer(_ current: AgentUsage?, _ incoming: AgentUsage) -> AgentUsage {
        guard let current, let currentAt = current.observedAt, let incomingAt = incoming.observedAt else {
            return incoming
        }
        return incomingAt >= currentAt ? incoming : current
    }

    /// What the Usage section is given for Claude: the newest reading; failing that, why none
    /// can come; failing that, nil — no reading yet.
    public static func usage(reading: AgentUsage?, userOwnsStatusLine: Bool) -> AgentUsage? {
        if let reading { return reading }
        return userOwnsStatusLine ? .unavailable(.claude, reason: ownStatusLineReason) : nil
    }

    private struct Payload: Decodable {
        let rateLimits: Limits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    private struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        func usageWindow(label: String) -> UsageWindow {
            UsageWindow(label: label, usedPercent: usedPercentage, tokens: nil,
                        resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter ClaudeRateLimitsTests`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Usage/ClaudeRateLimits.swift Tests/LinkCKitTests/ClaudeRateLimitsTests.swift
git diff --cached --stat
git commit -m "feat(usage): decode the rate limits a status line reports"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 2: Route `status_line` reports in the hook server

**Files:**
- Modify: `Sources/LinkCKit/Hooks/HookServer.swift` (add `onStatusLine`, `statusLineEvent`, and the route in `respond`)
- Test: `Tests/LinkCKitTests/HooksTests.swift` (inside `final class HookServerTests`)

**Interfaces:**
- Consumes: `ClaudeRateLimits.decode(_:receivedAt:) throws -> AgentUsage?` (Task 1).
- Produces:
  - `HookServer.statusLineEvent: String` (`"status_line"`), a `public static let`
  - `HookServer.onStatusLine: (@Sendable (AgentUsage) -> Void)?`

- [ ] **Step 1: Write the failing tests**

In `Tests/LinkCKitTests/HooksTests.swift`, inside `HookServerTests`, add a second recorder next to `EventBox`:

```swift
    private final class ReadingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentUsage] = []

        func record(_ reading: AgentUsage) {
            lock.lock()
            stored.append(reading)
            lock.unlock()
        }

        var all: [AgentUsage] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func postStatusLine(port: UInt16, token: String?, body: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.setValue("status_line", forHTTPHeaderField: "X-LinkC-Event")
        if let token { request.setValue(token, forHTTPHeaderField: "X-LinkC-Token") }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private let rateLimitsBody = #"{"session_id":"c1","rate_limits":{"five_hour":{"used_percentage":66,"resets_at":1789980000},"seven_day":{"used_percentage":92,"resets_at":1790017200}}}"#
```

Then the tests:

```swift
    func testATokenedStatusLineDeliversClaudesLimitsAndNoSessionEvent() async throws {
        let server = HookServer(port: 0)
        server.requiredToken = "tok"
        let events = EventBox()
        let readings = ReadingBox()
        server.onEvent = { events.record($0) }
        server.onStatusLine = { readings.record($0) }
        try server.start()
        defer { server.stop() }

        let (data, response) = try await postStatusLine(port: server.port, token: "tok", body: rateLimitsBody)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
        XCTAssertEqual(readings.all.count, 1)
        XCTAssertEqual(readings.all.first?.windows.map(\.usedPercent), [66, 92])
        XCTAssertTrue(events.all.isEmpty, "a status line report is not a session event")
    }

    func testAStatusLineWithTheWrongTokenDeliversNothing() async throws {
        let server = HookServer(port: 0)
        server.requiredToken = "tok"
        let readings = ReadingBox()
        server.onStatusLine = { readings.record($0) }
        try server.start()
        defer { server.stop() }

        let (_, wrong) = try await postStatusLine(port: server.port, token: "wrong", body: rateLimitsBody)
        let (_, missing) = try await postStatusLine(port: server.port, token: nil, body: rateLimitsBody)

        XCTAssertEqual(wrong.statusCode, 200)
        XCTAssertEqual(missing.statusCode, 200)
        XCTAssertTrue(readings.all.isEmpty)
    }

    func testAStatusLineWithoutRateLimitsDeliversNothingButStillAnswers() async throws {
        let server = HookServer(port: 0)
        server.requiredToken = "tok"
        let readings = ReadingBox()
        server.onStatusLine = { readings.record($0) }
        try server.start()
        defer { server.stop() }

        let (_, noLimits) = try await postStatusLine(port: server.port, token: "tok", body: #"{"session_id":"c1"}"#)
        let (_, notJSON) = try await postStatusLine(port: server.port, token: "tok", body: "not json")

        XCTAssertEqual(noLimits.statusCode, 200)
        XCTAssertEqual(notJSON.statusCode, 200, "an unreadable report is logged, and the status line never waits on it")
        XCTAssertTrue(readings.all.isEmpty)
    }
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter HookServerTests`
Expected: build failure — `value of type 'HookServer' has no member 'onStatusLine'`.

- [ ] **Step 3: Implement**

In `Sources/LinkCKit/Hooks/HookServer.swift`:

1. Below `private var _onEvent: ...`, add the stored callback:

```swift
    private var _onStatusLine: (@Sendable (AgentUsage) -> Void)?
```

2. Below the `onEvent` property, add:

```swift
    /// The `X-LinkC-Event` value of the status line linkC gives each Claude session
    /// (`SettingsComposer.statusLine`). Its body is Claude's status JSON, not a hook payload.
    public static let statusLineEvent = "status_line"

    /// Called with Claude's rate limits each time a session's status line reports them. Same
    /// queue, locking, and speed rules as `onEvent`.
    public var onStatusLine: (@Sendable (AgentUsage) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onStatusLine }
        set { stateLock.lock(); _onStatusLine = newValue; stateLock.unlock() }
    }
```

3. Replace `respond(on:request:)` and `tokenMatches(_:)` with:

```swift
    /// Decode (if recognized) then ALWAYS respond 200 `{}` immediately — no other work on
    /// this path. Never withholds or delays the response for an unrecognized event, and
    /// never returns anything but success: this must never be able to deny a Claude tool.
    private func respond(on connection: NWConnection, request: ParsedRequest) {
        if tokenMatches(request.headers) {
            if Self.header("X-LinkC-Event", in: request.headers) == Self.statusLineEvent {
                deliverStatusLine(request.body)
            } else if let event = HookEventDecoder.decode(headers: request.headers, body: request.body) {
                onEvent?(event) // synchronized read (see `onEvent`)
            }
        }

        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.untrack(connection)
            connection.cancel()
        })
    }

    /// A body with no windows is normal (an API-key plan, or before a session's first reply) and
    /// delivers nothing. One that is not Claude's status JSON is logged: a renamed field must not
    /// read as "no reading yet" forever without a trace.
    private func deliverStatusLine(_ body: Data) {
        do {
            if let reading = try ClaudeRateLimits.decode(body, receivedAt: Date()) {
                onStatusLine?(reading)
            }
        } catch {
            NSLog("linkC: a status line report could not be read — %@", String(describing: error))
        }
    }

    /// True when no token is required, or the request's `X-LinkC-Token` equals the required one.
    private func tokenMatches(_ headers: [String: String]) -> Bool {
        guard let required = requiredToken else { return true }
        return Self.header("X-LinkC-Token", in: headers) == required
    }

    /// Case-insensitive header lookup, matching the decoder's convention.
    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter HookServerTests`
Expected: all `HookServerTests` pass, including the three new ones.
Also run: `swift test --filter AppCoordinatorIntegrationTests` — expected: all pass (token and event routing unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Hooks/HookServer.swift Tests/LinkCKitTests/HooksTests.swift
git diff --cached --stat
git commit -m "feat(hooks): route status line reports to their own callback"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 3: Add linkC's status line to each session's settings

**Files:**
- Modify: `Sources/LinkCKit/Hooks/SettingsComposer.swift`
- Test: `Tests/LinkCKitTests/HooksTests.swift` (inside `final class SettingsComposerTests`)

**Interfaces:**
- Consumes: `HookServer.statusLineEvent` (Task 2).
- Produces:
  - `SettingsComposer.compose(userSettings: Data?, projectSettings: Data?, projectLocalSettings: Data? = nil, port: UInt16, token: String) throws -> Data` (new defaulted parameter; existing callers compile unchanged)
  - `SettingsComposer.statusLine(port: UInt16, token: String) -> [String: Any]`
  - `SettingsComposer.definesStatusLine(user: Data?, project: Data?, projectLocal: Data?) throws -> Bool`

- [ ] **Step 1: Write the failing tests**

Add to `SettingsComposerTests`:

```swift
    private func composedStatusLine(user: String? = nil, project: String? = nil, local: String? = nil) throws -> [String: Any]? {
        let composed = try SettingsComposer.compose(
            userSettings: user.map { Data($0.utf8) }, projectSettings: project.map { Data($0.utf8) },
            projectLocalSettings: local.map { Data($0.utf8) }, port: 4242, token: "tok-test")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: composed) as? [String: Any])
        return decoded["statusLine"] as? [String: Any]
    }

    func testComposeAddsASilentStatusLinePostingToTheHookServer() throws {
        let statusLine = try XCTUnwrap(try composedStatusLine())
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(
            statusLine["command"] as? String,
            "curl -s -m 2 -X POST -H 'X-LinkC-Token: tok-test' -H 'X-LinkC-Event: status_line' --data-binary @- http://127.0.0.1:4242/hook >/dev/null")
    }

    func testComposeKeepsTheUsersOwnStatusLine() throws {
        let statusLine = try composedStatusLine(user: #"{"statusLine": {"type": "command", "command": "~/.claude/sl.sh"}}"#)
        XCTAssertEqual(statusLine?["command"] as? String, "~/.claude/sl.sh")
    }

    func testComposeKeepsTheProjectsOwnStatusLine() throws {
        let statusLine = try composedStatusLine(project: #"{"statusLine": {"type": "command", "command": "./sl.sh"}}"#)
        XCTAssertEqual(statusLine?["command"] as? String, "./sl.sh")
    }

    /// Claude applies the project's local settings itself, under `--settings`: a status line
    /// linkC added would override the user's, so it adds none.
    func testComposeAddsNoStatusLineWhenTheProjectsLocalSettingsHaveOne() throws {
        XCTAssertNil(try composedStatusLine(local: #"{"statusLine": {"type": "command", "command": "./mine.sh"}}"#))
    }

    func testDefinesStatusLineLooksAtEveryLayerAndFailsLoudOnBadJSON() throws {
        let own = Data(#"{"statusLine": {"type": "command", "command": "x"}}"#.utf8)
        XCTAssertFalse(try SettingsComposer.definesStatusLine(user: nil, project: nil, projectLocal: nil))
        XCTAssertTrue(try SettingsComposer.definesStatusLine(user: own, project: nil, projectLocal: nil))
        XCTAssertTrue(try SettingsComposer.definesStatusLine(user: nil, project: own, projectLocal: nil))
        XCTAssertTrue(try SettingsComposer.definesStatusLine(user: nil, project: nil, projectLocal: own))
        XCTAssertThrowsError(try SettingsComposer.definesStatusLine(user: nil, project: nil, projectLocal: Data("{".utf8)))
    }
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter SettingsComposerTests`
Expected: build failure — `extra argument 'projectLocalSettings' in call`.

- [ ] **Step 3: Implement**

In `Sources/LinkCKit/Hooks/SettingsComposer.swift`:

1. Replace the `compose` signature and doc comment, and add the status line after the hooks merge:

```swift
    /// Deep-merge user + project settings with linkC hooks. Appends to existing hook
    /// arrays rather than clobbering them. Adds linkC's status line unless any settings layer —
    /// including the project's local settings, which Claude applies itself — sets its own.
    public static func compose(
        userSettings: Data?, projectSettings: Data?, projectLocalSettings: Data? = nil,
        port: UInt16, token: String
    ) throws -> Data {
```

and, directly after the line `merged["hooks"] = concatHookArrays(...)`, add:

```swift
        if try !definesStatusLine(user: userSettings, project: projectSettings, projectLocal: projectLocalSettings) {
            merged["statusLine"] = statusLine(port: port, token: token)
        }
```

2. Below `linkcHooks(port:token:)`, add:

```swift
    /// The status line linkC adds: it posts Claude's status JSON to the hook server and prints
    /// nothing, so no status row appears. Any status line makes Claude drop the "esc to
    /// interrupt" hint from its footer; Esc itself still works.
    public static func statusLine(port: UInt16, token: String) -> [String: Any] {
        [
            "type": "command",
            "command": "curl -s -m 2 -X POST -H 'X-LinkC-Token: \(token)' -H 'X-LinkC-Event: \(HookServer.statusLineEvent)' --data-binary @- http://127.0.0.1:\(port)/hook >/dev/null",
        ]
    }

    /// True when any settings layer sets its own `statusLine` — linkC never replaces one.
    public static func definesStatusLine(user: Data?, project: Data?, projectLocal: Data?) throws -> Bool {
        let layers: [(label: String, data: Data?)] = [("user", user), ("project", project), ("project local", projectLocal)]
        for layer in layers {
            if try decodeSettingsObject(layer.data, label: layer.label)["statusLine"] != nil {
                return true
            }
        }
        return false
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter SettingsComposerTests`
Expected: all pass (existing ones unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Hooks/SettingsComposer.swift Tests/LinkCKitTests/HooksTests.swift
git diff --cached --stat
git commit -m "feat(hooks): give each session a silent status line, never over the user's own"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 4: One rule table for every agent's row

**Files:**
- Modify: `Sources/LinkCKit/Usage/UsageRows.swift` (rewrite `build` and its helpers; keep `UsageRow`, `UnknownUsage`, `Result`, `order`, `silentSourceReason`)
- Test: `Tests/LinkCKitTests/UsageRowsTests.swift` (replace the whole file)

**Interfaces:**
- Consumes: `ClaudeRateLimits.ownStatusLineReason` (Task 1), `AgentUsage`, `UsageWindow`, `AgentLimitStatus`, `AgeFormat.compact(_:)`, `AgeFormat.compact(from:to:)`, `AgeFormat.longSpan(_:)`.
- Produces:
  - `UsageRows.build(claude: AgentUsage?, codex: AgentUsage?, limits: [AgentKind: AgentLimitStatus], now: Date = Date()) -> UsageRows.Result` (the `claude` parameter changes from `WindowUsage?`)
  - `UsageRows.claudeNoReadingReason: String`

Note: `Sources/linkc/AppModel+Sidebar.swift` still passes `usage.window` (a `WindowUsage?`) and will not compile after this task. That is expected: `LinkCKit` tests build without the app target. Task 6 fixes the call site. Run only `swift test --filter UsageRowsTests` here. That builds the `LinkCKit` and test targets, not the `linkc` app.

- [ ] **Step 1: Write the failing tests**

Replace `Tests/LinkCKitTests/UsageRowsTests.swift` with:

```swift
import XCTest
@testable import LinkCKit

final class UsageRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A reading as either provider reports it: a 5-hour window and a weekly one.
    private func reading(
        _ agent: AgentKind = .codex, percent: Double?, resetsIn: TimeInterval? = 3600,
        weekPercent: Double? = 31, weekResetsIn: TimeInterval = 86_400,
        observedAgo: TimeInterval = 120, plan: String? = "pro", reason: String? = nil
    ) -> AgentUsage {
        var windows: [UsageWindow] = []
        if let percent {
            windows.append(UsageWindow(
                label: "5h", usedPercent: percent, tokens: nil,
                resetsAt: resetsIn.map { now.addingTimeInterval($0) }))
        }
        if let weekPercent {
            windows.append(UsageWindow(
                label: "7d", usedPercent: weekPercent, tokens: nil,
                resetsAt: now.addingTimeInterval(weekResetsIn)))
        }
        return AgentUsage(
            agent: agent, windows: windows, planType: plan,
            observedAt: reason == nil ? now.addingTimeInterval(-observedAgo) : nil,
            unavailableReason: reason)
    }

    private func cap(_ agent: AgentKind, clearsIn: TimeInterval, reason: String = "usage cap") -> AgentLimitStatus {
        AgentLimitStatus(
            agent: agent, reason: reason, limitedAt: now.addingTimeInterval(-60),
            cooldownExpiresAt: now.addingTimeInterval(clearsIn))
    }

    private func build(
        claude: AgentUsage? = nil, codex: AgentUsage? = nil, limits: [AgentKind: AgentLimitStatus] = [:]
    ) -> UsageRows.Result {
        UsageRows.build(claude: claude, codex: codex, limits: limits, now: now)
    }

    private func row(_ result: UsageRows.Result, _ agent: AgentKind) -> UsageRow? {
        result.rows.first { $0.agent == agent }
    }

    func testTheRowOrderIsFixed() {
        let result = build(
            claude: reading(.claude, percent: 37, plan: nil),
            codex: reading(percent: 68),
            limits: [.cursor: cap(.cursor, clearsIn: 10_800), .agy: cap(.agy, clearsIn: 600)])
        XCTAssertEqual(result.rows.map(\.agent), [.claude, .codex, .cursor, .agy])
        XCTAssertTrue(result.unknown.isEmpty)
    }

    func testARowShowsTheFiveHourPercentageAndReset() {
        let result = build(codex: reading(percent: 68))
        XCTAssertEqual(row(result, .codex)?.text, "68% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertEqual(row(result, .codex)?.isStale, false)
        XCTAssertEqual(row(result, .codex)?.help, "7d 31% · resets 1d · pro · read 2m ago")
    }

    func testClaudesRowTakesTheSameShape() {
        let result = build(claude: reading(.claude, percent: 37, resetsIn: 7200, weekPercent: 41, plan: nil))
        XCTAssertEqual(row(result, .claude)?.text, "37% · resets 2h")
        XCTAssertEqual(row(result, .claude)?.help, "7d 41% · resets 1d · read 2m ago")
        XCTAssertEqual(result.headline, "37%")
    }

    func testTheCoralThresholdStartsAtEighty() {
        XCTAssertEqual(build(codex: reading(percent: 79.4)).rows.first?.isCoral, false)
        XCTAssertEqual(build(codex: reading(percent: 80)).rows.first?.isCoral, true)
        let roundsUp = build(codex: reading(percent: 79.6)).rows.first
        XCTAssertEqual(roundsUp?.isCoral, true, "79.6 rounds to 80, the same figure the text prints")
        XCTAssertEqual(roundsUp?.text, "80% · resets 1h")
    }

    func testAHighWeeklyWindowShowsInHelpButLeavesTheFigureQuiet() {
        let result = build(codex: reading(percent: 22, weekPercent: 92))
        XCTAssertEqual(row(result, .codex)?.text, "22% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertEqual(row(result, .codex)?.help.hasPrefix("7d 92% · resets 1d"), true)
        XCTAssertEqual(result.headline, "22%")
    }

    func testAFullFiveHourWindowSaysTheSessionLimitIsHit() {
        let result = build(claude: reading(.claude, percent: 100, resetsIn: 7200, plan: nil))
        XCTAssertEqual(row(result, .claude)?.text, "session limit hit · resets 2h")
        XCTAssertEqual(row(result, .claude)?.isCoral, true)
        XCTAssertEqual(row(result, .claude)?.isStale, false)
        XCTAssertEqual(row(result, .claude)?.help, "7d 31% · resets 1d · read 2m ago")
        XCTAssertEqual(result.headline, "limit hit")
    }

    func testAFullWeeklyWindowSaysTheWeeklyLimitIsHit() {
        let result = build(codex: reading(percent: 22, weekPercent: 100, weekResetsIn: 3 * 86_400))
        XCTAssertEqual(row(result, .codex)?.text, "weekly limit hit · resets 3d")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(row(result, .codex)?.help, "5h 22% · resets 1h · pro · read 2m ago")
        XCTAssertEqual(result.headline, "limit hit")
    }

    func testTheWeeklyHitOutranksTheSessionHit() {
        let result = build(codex: reading(percent: 100, weekPercent: 100))
        XCTAssertEqual(row(result, .codex)?.text, "weekly limit hit · resets 1d")
    }

    func testAHitComparesTheRoundedPercentage() {
        XCTAssertEqual(build(codex: reading(percent: 99.6)).rows.first?.text, "session limit hit · resets 1h")
        XCTAssertEqual(build(codex: reading(percent: 99.4)).rows.first?.text, "99% · resets 1h")
    }

    func testAStaleFullWindowIsNotAHit() {
        let result = build(codex: reading(percent: 100, weekPercent: 100, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(row(result, .codex)?.text, "100% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isStale, true)
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testAFullWindowThatHasResetIsStaleNotAHit() {
        let result = build(codex: reading(percent: 100, resetsIn: -60))
        XCTAssertEqual(row(result, .codex)?.text, "100%", "the window moved on: no reset is claimed")
        XCTAssertEqual(row(result, .codex)?.isStale, true)
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertNil(result.headline, "the 5-hour window rolled over, so there is no live 5-hour figure")
        XCTAssertEqual(row(result, .codex)?.help.hasPrefix("window has since reset; this was the reading before it"), true)
    }

    func testAFigureWithNoResetTimeStandsAlone() {
        XCTAssertEqual(build(codex: reading(percent: 68, resetsIn: nil)).rows.first?.text, "68%")
    }

    func testAnOldReadingIsStaleAndNeverCoral() {
        let result = build(codex: reading(percent: 92, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(result.rows.first?.isStale, true)
        XCTAssertEqual(result.rows.first?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testACapWinsOverEveryOtherSource() {
        let result = build(codex: reading(percent: 12), limits: [.codex: cap(.codex, clearsIn: 900)])
        XCTAssertEqual(row(result, .codex)?.text, "limit hit · retry 15m")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(row(result, .codex)?.help.contains("usage cap"), true)
        XCTAssertEqual(row(result, .codex)?.help.contains("retry is linkC's own wait, not the provider's reset"), true)
        XCTAssertEqual(result.headline, "limit hit")
    }

    func testAnExpiredCapFallsThroughToNoUsageData() {
        let expired = AgentLimitStatus(
            agent: .cursor, reason: "usage cap", limitedAt: now.addingTimeInterval(-7200),
            cooldownExpiresAt: now.addingTimeInterval(-60))
        let result = build(limits: [.cursor: expired])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.unknown.map(\.agent), UsageRows.order)
    }

    func testAgentsWithNoSourceAreListedWithTheirReason() {
        let result = build(codex: reading(percent: nil, weekPercent: nil, reason: "no session records found"))
        XCTAssertEqual(result.unknown.map(\.agent), [.claude, .codex, .cursor, .agy])
        XCTAssertEqual(result.unknown.first { $0.agent == .claude }?.reason,
                       "no reading yet — a Claude session reports after its first reply")
        XCTAssertEqual(result.unknown.first { $0.agent == .codex }?.reason, "no session records found")
        XCTAssertEqual(result.unknown.first { $0.agent == .cursor }?.reason.isEmpty, false)
        XCTAssertEqual(result.unknown.first { $0.agent == .agy }?.reason.isEmpty, false)
    }

    func testClaudeWithItsOwnStatusLineSaysWhy() {
        let result = build(claude: .unavailable(.claude, reason: ClaudeRateLimits.ownStatusLineReason))
        XCTAssertNil(row(result, .claude))
        XCTAssertEqual(result.unknown.first { $0.agent == .claude }?.reason, ClaudeRateLimits.ownStatusLineReason)
    }

    func testTheHeadlineIsTheHighestLiveFiveHourPercentage() {
        XCTAssertEqual(build(claude: reading(.claude, percent: 37), codex: reading(percent: 68)).headline, "68%")
        XCTAssertNil(build().headline)
    }

    func testAReadingWithNoFiveHourWindowUsesTheWindowItHas() {
        let result = build(codex: reading(percent: nil, weekPercent: 55))
        XCTAssertEqual(row(result, .codex)?.text, "55% · resets 1d")
        XCTAssertEqual(row(result, .codex)?.help, "pro · read 2m ago")
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter UsageRowsTests`
Expected: build failure — `cannot convert value of type 'AgentUsage?' to expected argument type 'WindowUsage?'`.

- [ ] **Step 3: Implement**

In `Sources/LinkCKit/Usage/UsageRows.swift`:

1. Update the `UsageRow.text` doc comment:

```swift
    /// What the row says on the right: "37% · resets 2h", "weekly limit hit · resets 3d",
    /// "limit hit · retry 15m".
    public let text: String
```

2. Update the `Result.headline` doc comment:

```swift
        /// The section label's trailing text: "limit hit" when any row shows one, else the
        /// highest live 5-hour percentage.
        public let headline: String?
```

3. Below `order`, add:

```swift
    /// Claude's reason before any of its sessions has reported through the status line.
    public static let claudeNoReadingReason = "no reading yet — a Claude session reports after its first reply"
```

4. Replace `build(...)` and everything below it in the enum (`figure`, `roundedPercent`, `percentText`, `codexHelp`) with:

```swift
    public static func build(
        claude: AgentUsage?,
        codex: AgentUsage?,
        limits: [AgentKind: AgentLimitStatus],
        now: Date = Date()
    ) -> Result {
        var rows: [UsageRow] = []
        var unknown: [UnknownUsage] = []
        var livePercentages: [Int] = []
        var anyLimitHit = false

        for agent in order {
            // A cap linkC watched happen outranks every other source: it is the hardest fact
            // available, and while it holds the published figures cannot be acted on anyway.
            if let limit = limits[agent], limit.cooldownExpiresAt > now {
                anyLimitHit = true
                rows.append(UsageRow(
                    agent: agent,
                    text: "limit hit · retry \(AgeFormat.compact(from: now, to: limit.cooldownExpiresAt))",
                    isCoral: true,
                    isStale: false,
                    help: "\(limit.reason) · seen \(AgeFormat.compact(from: limit.limitedAt, to: now)) ago · retry is linkC's own wait, not the provider's reset"))
                continue
            }

            let usage: AgentUsage?
            let notReadReason: String
            switch agent {
            case .claude:
                usage = claude
                notReadReason = claudeNoReadingReason
            case .codex:
                usage = codex
                notReadReason = "not read yet"
            case .cursor, .agy, .shell:
                unknown.append(UnknownUsage(agent: agent, reason: silentSourceReason(agent)))
                continue
            }
            guard let usage else {
                unknown.append(UnknownUsage(agent: agent, reason: notReadReason))
                continue
            }
            guard let windowRow = windowRow(agent: agent, usage: usage, now: now) else {
                unknown.append(UnknownUsage(
                    agent: agent, reason: usage.unavailableReason ?? "no window percentage reported"))
                continue
            }
            rows.append(windowRow.row)
            if windowRow.isLimitHit { anyLimitHit = true }
            if let percent = windowRow.liveFigurePercent { livePercentages.append(percent) }
        }

        return Result(
            rows: rows,
            unknown: unknown,
            headline: anyLimitHit ? "limit hit" : livePercentages.max().map { "\($0)%" })
    }

    private struct WindowRow {
        let row: UsageRow
        let isLimitHit: Bool
        /// The figure's rounded percentage while its window is live — what the headline compares.
        let liveFigurePercent: Int?
    }

    /// One agent's row from the windows its provider reports — the same rules for every agent.
    /// nil when no window carries a percentage.
    private static func windowRow(agent: AgentKind, usage: AgentUsage, now: Date) -> WindowRow? {
        // The figure is the 5-hour window when there is one — the window that usually bites
        // first — else whatever window the reading has.
        guard let figureWindow = usage.windows.first(where: { $0.label == "5h" }) ?? usage.windows.first,
              let percent = figureWindow.usedPercent
        else { return nil }

        let readingAge = usage.observedAt.map { now.timeIntervalSince($0) }
        let readingIsFresh = readingAge.map { $0 <= AgentUsage.staleAfter } ?? false
        // A window speaks for now only while the reading is fresh and the window has not rolled over.
        func isLive(_ window: UsageWindow) -> Bool {
            readingIsFresh && window.usedPercent != nil && !(window.resetsAt.map { $0 <= now } ?? false)
        }
        func isFull(_ window: UsageWindow) -> Bool {
            isLive(window) && roundedPercent(window.usedPercent!) >= 100
        }
        let liveFigurePercent = isLive(figureWindow) ? roundedPercent(percent) : nil

        // A full weekly window outranks a full 5-hour one: it is the longer wait.
        let hit: (window: UsageWindow, name: String)?
        if let week = usage.windows.first(where: { $0.label == "7d" }), isFull(week) {
            hit = (week, "weekly")
        } else if let session = usage.windows.first(where: { $0.label == "5h" }), isFull(session) {
            hit = (session, "session")
        } else {
            hit = nil
        }

        if let hit {
            return WindowRow(
                row: UsageRow(
                    agent: agent,
                    text: "\(hit.name) limit hit" + resetsSuffix(hit.window.resetsAt, now: now),
                    isCoral: true,
                    isStale: false,
                    help: help(usage, other: usage.windows.first { $0.label != hit.window.label },
                               readingAge: readingAge, notice: nil, now: now)),
                isLimitHit: true,
                liveFigurePercent: liveFigurePercent)
        }

        // Stale two ways: the reading itself is old, or the window it describes has already
        // rolled over. Either way the number might no longer be true.
        let windowRolled = figureWindow.resetsAt.map { $0 <= now } ?? false
        return WindowRow(
            row: UsageRow(
                agent: agent,
                text: percentText(percent) + resetsSuffix(figureWindow.resetsAt, now: now),
                isCoral: liveFigurePercent.map { $0 >= Int(AgentUsage.warnThreshold) } ?? false,
                isStale: !readingIsFresh || windowRolled,
                help: help(usage, other: usage.windows.first { $0.label != figureWindow.label },
                           readingAge: readingAge,
                           notice: windowRolled ? "window has since reset; this was the reading before it" : nil,
                           now: now)),
            isLimitHit: false,
            liveFigurePercent: liveFigurePercent)
    }

    /// " · resets 2h", or nothing when no future reset is known. Under a day the wait reads in
    /// minutes or hours; from a day on, in days, so a weekly reset never reads "72h".
    private static func resetsSuffix(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt > now else { return "" }
        let remaining = resetsAt.timeIntervalSince(now)
        let wait = remaining < 86_400 ? AgeFormat.compact(remaining) : AgeFormat.longSpan(remaining)
        return " · resets \(wait)"
    }

    /// Rounded once, so the figure printed and the figure compared against a threshold always
    /// agree — a value that displays as "80%" must also be treated as 80, never as 79.6.
    private static func roundedPercent(_ percent: Double) -> Int {
        Int(percent.rounded())
    }

    private static func percentText(_ percent: Double) -> String {
        "\(roundedPercent(percent))%"
    }

    /// The hover text: a notice when there is one, the window the row is not showing, the plan,
    /// and how old the reading is.
    private static func help(
        _ usage: AgentUsage, other: UsageWindow?, readingAge: TimeInterval?, notice: String?, now: Date
    ) -> String {
        var parts: [String] = []
        if let notice { parts.append(notice) }
        if let other, let percent = other.usedPercent {
            parts.append("\(other.label) \(percentText(percent))" + resetsSuffix(other.resetsAt, now: now))
        }
        if let plan = usage.planType, !plan.isEmpty { parts.append(plan) }
        if let readingAge { parts.append("read \(AgeFormat.compact(readingAge)) ago") }
        return parts.joined(separator: " · ")
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter UsageRowsTests`
Expected: `Executed 19 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Usage/UsageRows.swift Tests/LinkCKitTests/UsageRowsTests.swift
git diff --cached --stat
git commit -m "feat(usage): one row shape for every agent: 5-hour figure or the limit hit"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 5: Read Claude's spinner row when its footer has no hint

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalPreview.swift` (`liveActivity(from:)`, plus a new glyph set and helper)
- Test: `Tests/LinkCKitTests/TerminalTests.swift` (add next to `testLiveActivityReadsAFinishedClaudeTurnAsIdle`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: no new public API; `TerminalPreview.liveActivity(from:)` returns Claude's spinner phrase when the footer has no "esc to interrupt".

- [ ] **Step 1: Write the failing tests**

Add to the test class that holds `testLiveActivityReadsAFinishedClaudeTurnAsIdle` in `Tests/LinkCKitTests/TerminalTests.swift`:

```swift
    /// With a status line configured, Claude drops "esc to interrupt" from its footer, so the
    /// spinner row above the input box is what says a turn runs. The first three frames were
    /// captured from Claude Code 2.1.278 launched with linkC's flags and an empty status line.
    func testLiveActivityReadsClaudesSpinnerRowWhenTheFooterHasNoHint() {
        let rule = String(repeating: "─", count: 110)
        let footer = "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"

        let thinking = [
            "✳ Bunning… (2s · thinking with xhigh effort)",
            "                                                                                           ◉ xhigh · /effort",
            rule, "❯ ", rule, footer,
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: thinking), "Bunning…")

        let underABanner = [
            "✶ Bunning… (3s · thinking with xhigh effort)",
            "                                         You've used 92% of your weekly limit · resets 2pm (America/Chicago)",
            rule, "❯ ", rule, footer,
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: underABanner), "Bunning…")

        let countingTokens = [
            "  Waiting 12 seconds · 7s",
            "  ⎿  $ sleep 12 (8s)",
            "     (ctrl+b ctrl+b (twice) to run in background)",
            "✽ Bunning… (12s · ↓ 417 tokens)",
            rule, "❯ ", rule, footer,
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: countingTokens), "Bunning…")

        // Constructed: Claude's todo list renders under the spinner row.
        let withTodos = [
            "✻ Bunning… (1m 4s · ↓ 2.1k tokens)",
            "  ⎿  ☒ Read the config",
            "     ☐ Write the test",
            rule, "❯ ", rule, footer,
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: withTodos), "Bunning…")
    }

    /// The nearest glyph-led row above the box decides: a finished turn's summary has no timer.
    func testLiveActivityReadsAFinishedClaudeTurnWithNoFooterHintAsIdle() {
        let rule = String(repeating: "─", count: 110)
        let footer = "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
        let finished = [
            "✳ Bunning… (12s · ↓ 417 tokens)",
            "⏺ done",
            "✻ Brewed for 18s · done 4:40 PM",
            rule, "❯ ", rule, footer,
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: finished))

        let noSpinnerAtAll = ["⏺ done", rule, "❯ ", rule, footer]
        XCTAssertNil(TerminalPreview.liveActivity(from: noSpinnerAtAll))
    }
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter TerminalTests`
Expected: `testLiveActivityReadsClaudesSpinnerRowWhenTheFooterHasNoHint` fails (`nil` is not equal to `"Bunning…"`). The idle test already passes.

- [ ] **Step 3: Implement**

In `Sources/LinkCKit/Terminal/TerminalPreview.swift`, inside `liveActivity(from:)`, the prompt-row branch currently ends:

```swift
                if let status = above.first, status.contains("esc to interrupt)") {
                    let unbulleted = status.hasPrefix("•") ? String(status.dropFirst()).trimmingCharacters(in: .whitespaces) : status
                    return spinnerPhrase(unbulleted) ?? "Working"
                }
                return nil
```

Replace the final `return nil` so it reads:

```swift
                if let status = above.first, status.contains("esc to interrupt)") {
                    let unbulleted = status.hasPrefix("•") ? String(status.dropFirst()).trimmingCharacters(in: .whitespaces) : status
                    return spinnerPhrase(unbulleted) ?? "Working"
                }
                // Claude with a status line has no working footer either: its spinner row above
                // the box is what says the turn runs.
                return claudeSpinnerPhrase(nearestGlyphRowIn: above)
```

Then add, next to `isWorkingFooter(_:)`:

```swift
    /// The glyphs that lead Claude Code's spinner row while a turn runs.
    private static let claudeSpinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "*"]

    /// The phrase on Claude Code's live spinner row: a spinner glyph, a phrase ending in "…",
    /// then a running timer — "✳ Bunning… (2s · thinking with xhigh effort)" gives "Bunning…".
    /// The nearest glyph-led row decides, so a finished turn's "✻ Brewed for 18s" (no timer)
    /// reads as idle. Rows led by anything else — banners, the effort badge, todo rows, tool
    /// output — are passed over. `rows` holds visible text, nearest the input box first.
    private static func claudeSpinnerPhrase<Rows: Sequence>(nearestGlyphRowIn rows: Rows) -> String?
    where Rows.Element == String {
        guard let row = rows.first(where: { $0.first.map { claudeSpinnerGlyphs.contains($0) } ?? false }) else {
            return nil
        }
        let phrase = row.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let timer = phrase.range(of: #"… \(\d+[hms]"#, options: .regularExpression) else { return nil }
        let words = phrase[..<timer.lowerBound].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words + "…"
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter TerminalTests`
Expected: all pass, including `testLiveActivityReadsAFinishedClaudeTurnAsIdle` and the footer-path tests.
Also run: `swift test --filter TerminalSessionAgentTests` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/TerminalPreview.swift Tests/LinkCKitTests/TerminalTests.swift
git diff --cached --stat
git commit -m "fix(terminal): read the spinner row when the footer carries no interrupt hint"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 6: Wire the reading through the coordinator to the sidebar

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (stored reading, `claudeUsage`, `onStatusLine` in `start()`, `writeSettings(for:)`)
- Modify: `Sources/linkc/AppModel+Sidebar.swift:139-142` (`usageRows(now:)`)
- Modify: `Sources/linkc/Sidebar.swift` (`UsageRowView.figureColor` comment)
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`

**Interfaces:**
- Consumes: `HookServer.onStatusLine`, `HookServer.statusLineEvent` (Task 2); `SettingsComposer.compose(userSettings:projectSettings:projectLocalSettings:port:token:)`, `SettingsComposer.definesStatusLine(user:project:projectLocal:)` (Task 3); `ClaudeRateLimits.newer`, `ClaudeRateLimits.usage(reading:userOwnsStatusLine:)`, `ClaudeRateLimits.ownStatusLineReason` (Task 1); `UsageRows.build(claude: AgentUsage?, ...)` (Task 4).
- Produces: `AppCoordinator.claudeUsage: AgentUsage?` (public, main actor).

- [ ] **Step 1: Write the failing tests**

Add to `AppCoordinatorIntegrationTests` (the class is `@MainActor` and already has `makeCoordinator`, `waitUntil`):

```swift
    /// A tokened status-line report from any Claude session becomes Claude's usage reading.
    func testAStatusLineReportBecomesClaudesUsage() async throws {
        let coordinator = makeCoordinator()
        try coordinator.start()
        defer { coordinator.shutdown() }
        XCTAssertNil(coordinator.claudeUsage, "no reading before any report")

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(coordinator.hookPort)/hook")!)
        request.httpMethod = "POST"
        request.setValue(HookServer.statusLineEvent, forHTTPHeaderField: "X-LinkC-Event")
        request.setValue(coordinator.hookToken, forHTTPHeaderField: "X-LinkC-Token")
        request.httpBody = Data(#"{"session_id":"c1","rate_limits":{"five_hour":{"used_percentage":66,"resets_at":1789980000},"seven_day":{"used_percentage":92,"resets_at":1790017200}}}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let arrived = try await waitUntil { coordinator.claudeUsage?.windows.count == 2 }
        XCTAssertTrue(arrived, "the reading must reach the coordinator")
        XCTAssertEqual(coordinator.claudeUsage?.windows.first { $0.label == "5h" }?.usedPercent, 66)
    }

    /// A launch with no status line of its own gets linkC's, carrying this run's token.
    func testALaunchGetsLinkCsStatusLine() throws {
        let settingsDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sl-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let coordinator = makeCoordinator(claudePath: "/bin/cat", settingsDir: settingsDir)

        let session = try coordinator.newSession(cwd: cwd.path, mode: .new)
        defer { coordinator.stopSession(session.id) }

        let file = settingsDir.appendingPathComponent("session-\(session.id).json")
        let composed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let statusLine = try XCTUnwrap(composed["statusLine"] as? [String: Any])
        XCTAssertEqual((statusLine["command"] as? String)?.contains(coordinator.hookToken), true)
        XCTAssertNil(coordinator.claudeUsage)
    }

    /// A project that runs its own status line keeps it: linkC adds none, and Claude's usage
    /// says why it has no figure.
    func testAProjectsOwnStatusLineIsKeptAndClaudesUsageSaysWhy() throws {
        let settingsDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sl-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        let dotClaude = cwd.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dotClaude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        try Data(#"{"statusLine": {"type": "command", "command": "echo mine"}}"#.utf8)
            .write(to: dotClaude.appendingPathComponent("settings.local.json"))
        let coordinator = makeCoordinator(claudePath: "/bin/cat", settingsDir: settingsDir)

        let session = try coordinator.newSession(cwd: cwd.path, mode: .new)
        defer { coordinator.stopSession(session.id) }

        let file = settingsDir.appendingPathComponent("session-\(session.id).json")
        let composed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(composed["statusLine"], "Claude applies the local status line itself; linkC must not override it")
        XCTAssertEqual(coordinator.claudeUsage?.unavailableReason, ClaudeRateLimits.ownStatusLineReason)
    }
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter AppCoordinatorIntegrationTests`
Expected: build failure — `value of type 'AppCoordinator' has no member 'claudeUsage'`.

- [ ] **Step 3: Implement the coordinator**

In `Sources/LinkCKit/App/AppCoordinator.swift`:

1. Next to the other stored state near `hookToken` (line ~57), add:

```swift
    /// Claude's newest rate-limit reading, from any linkC-launched session's status line. In
    /// memory only: after a relaunch the Usage row waits for the next report.
    private var claudeRateLimits: AgentUsage?
    /// Whether the latest Claude launch found a status line of the user's own, so linkC added none.
    private var claudeStatusLineIsUsers = false

    /// What the sidebar's Usage section shows for Claude.
    public var claudeUsage: AgentUsage? {
        ClaudeRateLimits.usage(reading: claudeRateLimits, userOwnsStatusLine: claudeStatusLineIsUsers)
    }
```

2. In `start()`, directly after the `hookServer.onEvent = { ... }` assignment, add:

```swift
        // Readings hop to the main actor in separate tasks; `newer` keeps the latest taken,
        // whatever order they land in.
        hookServer.onStatusLine = { [weak self] reading in
            Task { @MainActor in
                guard let self else { return }
                self.claudeRateLimits = ClaudeRateLimits.newer(self.claudeRateLimits, reading)
            }
        }
```

3. Replace the first four lines of `writeSettings(for:)` (from `let user =` through `let data = try SettingsComposer.compose(...)`) with:

```swift
        let user = try? Data(contentsOf: userSettingsURL)
        let projectDir = URL(fileURLWithPath: session.cwd).appendingPathComponent(".claude")
        let project = try? Data(contentsOf: projectDir.appendingPathComponent("settings.json"))
        let projectLocal = try? Data(contentsOf: projectDir.appendingPathComponent("settings.local.json"))
        let data = try SettingsComposer.compose(
            userSettings: user, projectSettings: project, projectLocalSettings: projectLocal,
            port: hookServer.port, token: hookToken)
        claudeStatusLineIsUsers = try SettingsComposer.definesStatusLine(
            user: user, project: project, projectLocal: projectLocal)
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter AppCoordinatorIntegrationTests`
Expected: all pass, including the three new ones.

- [ ] **Step 5: Wire the sidebar**

In `Sources/linkc/AppModel+Sidebar.swift`, replace `usageRows(now:)` with:

```swift
    /// The sidebar's Usage section: a row per agent that reports something, the rest listed with
    /// the reason they do not.
    func usageRows(now: Date = Date()) -> UsageRows.Result {
        UsageRows.build(claude: coordinator?.claudeUsage, codex: codexUsage, limits: agentLimits, now: now)
    }
```

In `Sources/linkc/Sidebar.swift`, `UsageRowView.figureColor`: a row can no longer be coral and stale at once (a hit needs a live window; a coral figure needs a live figure). Replace its comment so the property reads:

```swift
    private var figureColor: Color {
        // Coral is only ever set on a live figure, so it never meets dimming.
        if row.isCoral { return Theme.accent }
        return row.isStale ? Theme.textTertiary.opacity(0.7) : Theme.textTertiary
    }
```

- [ ] **Step 6: Build the app and run the full suite**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` (the `linkc` app target compiles against the new `UsageRows.build`).

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 1008 tests, with 5 tests skipped and 0 failures` (985 baseline, minus 16 old `UsageRowsTests`, plus 7 + 3 + 5 + 19 + 2 + 3 new).

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator.swift Sources/linkc/AppModel+Sidebar.swift Sources/linkc/Sidebar.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift
git diff --cached --stat
git commit -m "feat(usage): feed the status line's reading to the sidebar's row"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Final verification (controller, not a subagent)

- [ ] Run the real status-line command under the real CLI: launch `claude --dangerously-skip-permissions --settings <file>` in tmux, in a scratch folder, where `<file>` holds the `statusLine` that `SettingsComposer.statusLine(port:token:)` produces. Point it at a throwaway listener that prints the request's headers and body. Confirm one POST arrives with `X-LinkC-Event: status_line`, the token, and a `rate_limits` body, and that Claude's screen shows no status row.
- [ ] Revert-proof each task's core line (the `status_line` route, the `statusLine` insert, the hit branch, the spinner-row return, the `onStatusLine` assignment): its tests go red, then green again when restored.
- [ ] `./build-app.sh` ends with `==> Done:`.
