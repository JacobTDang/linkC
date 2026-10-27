# `linkc` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `linkc <agent> [--tier T] [--task] "prompt"` run in any terminal opens that agent in a new linkC window, in the current folder, with the prompt typed in. With `--task`, the session is a worker carrying a task pinned to it for the calling agent.

**Architecture:**
- **LinkCKit (pure, tested):**
  - pinned tasks (`TaskRecord.targetSessionId`, honored by `dispatchTasks`);
  - the request and result file exchange (`OpenRequest`, `OpenResult`, `OpenRequestStore`) and a folder watcher;
  - the command itself (`LinkCCommand.parse`/`run`, with injected outside world);
  - `AppCoordinator` answering requests in its sweep and typing the prompt once the agent is ready.
- **Executables and app:**
  - a `linkc-cli` target (installed as `~/.local/bin/linkc`);
  - `build-app.sh`;
  - the app tearing the new session off into a window.

**Tech Stack:** Swift 6, SwiftUI + AppKit, macOS 14, XCTest (`swift test`).

## Global Constraints
- Spec: `docs/superpowers/specs/2026-10-27-linkc-command-design.md` governs.
- **Base.** This branch builds on `fix/serve-mcp-folders` (PR A). `sweepTick` there already reads `mcpWorkspaces()` and relays server-only folders, and the `AppCoordinator` designated init already has `mcpWorkspaces:` after `sweepClock:`.
- **Agents.** `claude`, `codex`, `agy`, `cursor`, `grok` (every `AgentKind` except `.shell`).
- **Request folder.** `~/Library/Application Support/linkC/open-requests/`, mode 0700.
  - `<id>.json` is a request; `<id>.result.json` is its answer.
  - The command waits up to **20 s** for its answer.
  - linkC refuses a request older than **60 s**.
- **Success message.** `Opened <displayName> in a linkC window (<folder name>).` with exit 0.
- **Failures.** stderr, prefixed `linkc: `, exit 1. Usage errors exit 2 and print the usage.
- **Pinned task.**
  - It is delivered only to its target and never launches a session.
  - If its target has ended, it expires with the reason `its session ended before the task was delivered`.
  - It is created with `tier: nil`.
- **Prompt typing.** The prompt is typed once, through `terminals.sendInput` plus `recordInjection`. It waits for the same readiness as a task brief: the session is idle, paste has been negotiated and has settled past `deliverySettle`, and the injection gap has elapsed. It is dropped, with a log line, if the session ends, or if the agent is not ready within `pasteNegotiationTimeout`.
- **Code rules.**
  - No side effects in SwiftUI view bodies.
  - Fail loud: no swallowed errors; a logged repair is fine.
  - Swift 6 strict concurrency.
  - `swift build --build-tests` with 0 warnings.
  - No new dependencies.
- **Commits.**
  - No trailers of any kind.
  - Never mention Claude, Anthropic, AI or any assistant/tool name in a commit message.
  - `./scripts/check-commits.sh origin/main..HEAD` must be clean.
- **Never launch, quit, restart or signal linkC, and never run the built app.** Never run the built `linkc` CLI except with `--help` or arguments that fail to parse. A real run would ask the user's running linkC to open a window.

---

### Task 1: Pinned tasks (LinkCKit)

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxModels.swift` (`TaskRecord`)
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift` (`createTask`)
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`dispatchTasks`)
- Test: `Tests/LinkCKitTests/InboxStoreTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Produces:
  - `TaskRecord.targetSessionId: String?`, a `var`, with an init parameter `targetSessionId: String? = nil` placed last.
  - `InboxStore.createTask(..., fromSessionId: String? = nil, targetSessionId: String? = nil, tier: ...)`. The new parameter sits right after `fromSessionId`.

- [ ] **Step 1: Write the failing tests.** In `InboxStoreTests.swift`, add at class scope (the class already creates `InboxStore`s on temp folders, so follow its setup):

```swift
    /// The same work handed to two sessions opened with `linkc --task` is two tasks, one pinned to each.
    func testTheSameTaskPinnedToAnotherSessionIsANewTask() throws {
        let first = try store.createTask(from: .claude, to: .codex, targetSessionId: "S1", prompt: "carry", files: [])
        let second = try store.createTask(from: .claude, to: .codex, targetSessionId: "S2", prompt: "carry", files: [])

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.targetSessionId, "S1")
        XCTAssertEqual(second.targetSessionId, "S2")
    }

    func testATaskWrittenBeforePinningDecodesUnpinned() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "carry", files: [])
        XCTAssertNil(try store.task(id: task.id)?.targetSessionId)
    }
```

If the class names its store something other than `store`, use its name.

In `AppCoordinatorRelayTests.swift`, add at class scope:

```swift
    // MARK: - Pinned tasks (`linkc --task`)

    /// A task pinned to a session goes to that session, even while another idle session of the same
    /// agent, first in line, could carry it.
    @MainActor
    func testAPinnedTaskIsDeliveredOnlyToItsSession() async throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer {
            coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
            coordinator.shutdown()
        }
        let other = try coordinator.newSession(cwd: ws, agent: .codex)
        let pinned = try coordinator.newSession(cwd: ws, agent: .codex)
        for session in [other, pinned] {
            coordinator.store.updateState(id: session.id, to: .ready)
            try await waitForPasteReady(coordinator, sessionId: session.id)
        }
        let task = try inbox.createTask(from: .claude, to: .codex, targetSessionId: pinned.id, prompt: "carry", files: [])

        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertEqual(try inbox.task(id: task.id)?.assigneeSessionId, pinned.id)
    }

    /// A pinned task waits for its own session and never launches one.
    @MainActor
    func testAPinnedTaskWaitsForItsBusySessionAndLaunchesNone() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer {
            coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
            coordinator.shutdown()
        }
        let pinned = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: pinned.id, to: .working)
        let task = try inbox.createTask(from: .claude, to: .codex, targetSessionId: pinned.id, prompt: "carry", files: [])

        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertEqual(coordinator.store.sessions.map(\.id), [pinned.id], "no session was launched for it")
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
    }

    @MainActor
    func testAPinnedTaskWhoseSessionEndedExpires() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let task = try inbox.createTask(from: .claude, to: .codex, targetSessionId: "GONE", prompt: "carry", files: [])

        coordinator.processPendingMessages(workspacePath: ws)

        let after = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(after.state, .expired)
        XCTAssertEqual(after.cancelReason, "its session ended before the task was delivered")
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "no session was launched for it")
    }
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "InboxStoreTests|AppCoordinatorRelayTests"`. They fail to compile: `targetSessionId` does not exist yet.

- [ ] **Step 3: Implement.**
  - **`TaskRecord`** (`InboxModels.swift`). After `closeRequest`, add the property below, then the init parameter `targetSessionId: String? = nil` as the last parameter, and assign it in the init.
    ```swift
    /// The one session this task may be delivered to: the session the `linkc --task` command opened for
    /// it. nil: any session of `toAgent` that can carry it. Optional for the same reason as `tier`.
    public var targetSessionId: String?
    ```
  - **`InboxStore.createTask`:**
    - Add the parameter `targetSessionId: String? = nil` right after `fromSessionId: String? = nil`.
    - In the duplicate check, add `&& $0.targetSessionId == targetSessionId` to the `first(where:)` condition.
    - Pass `targetSessionId: targetSessionId` to the `TaskRecord(...)` call.
  - **`dispatchTasks`** (`AppCoordinator+Relay.swift`). Replace the `candidates` filter and the start of the `if candidates.isEmpty {` block with:
    ```swift
    let candidates = store.sessions.filter {
        $0.cwd == norm && $0.state != .ended && $0.canCarry(task)
            && (task.targetSessionId == nil || $0.id == task.targetSessionId)
    }
    if candidates.isEmpty {
        // A pinned task goes to its own session or nowhere: never to another, and no session is
        // launched for it. With its session gone before delivery there is nothing to deliver to.
        if let target = task.targetSessionId {
            if store.session(id: target).map({ $0.state == .ended }) ?? true {
                let reason = "its session ended before the task was delivered"
                do {
                    try inboxStore.expireTaskAndNotify(
                        taskId: task.id, reason: reason, notifyBody: "expired — \(reason)", timeout: Self.relayLockTimeout
                    )
                    logTaskEnded(task, as: "expired", reason: reason)
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchTasks: task %@ pinned session gone — %@", task.shortId, String(describing: error))
                }
            }
            continue
        }
    ```
    Leave the rest of the block unchanged: the tier check and the spawn that follow.

- [ ] **Step 4: Run the tests.** Run `swift test --filter "InboxStoreTests|InboxTaskLifecycleTests|AppCoordinatorRelayTests"`. All pass. `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing.

- [ ] **Step 5: Commit.** Commit the tests first (`test(tasks): a task can be pinned to one session`), then the implementation (`feat(tasks): a pinned task goes only to its own session and never launches one`).

---

### Task 2: The request and answer files (LinkCKit)

**Files:**
- Create: `Sources/LinkCKit/Command/OpenRequest.swift`
- Create: `Sources/LinkCKit/Command/FolderWatcher.swift`
- Test: `Tests/LinkCKitTests/OpenRequestStoreTests.swift`, `Tests/LinkCKitTests/FolderWatcherTests.swift`

**Interfaces (produced, used by Tasks 3 to 5):**
- **`OpenRequest`.** `public struct OpenRequest: Codable, Equatable, Sendable` with these fields:
  - `id: String`
  - `agent: AgentKind`
  - `folder: String`
  - `prompt: String?`
  - `tier: ModelTier?`
  - `task: OpenRequest.TaskOrigin?`, where `TaskOrigin` holds `fromAgent: AgentKind` and `fromSessionId: String?`
  - `createdAt: Date`

  Its init is `init(id: String = UUID().uuidString, agent:, folder:, prompt:, tier:, task:, createdAt: Date = Date())`.
- **`OpenResult`.** `public struct OpenResult: Codable, Equatable, Sendable` with `ok: Bool`, `sessionId: String?` and `message: String`, plus `static func opened(sessionId:message:)` and `static func refused(_:)`.
- **`OpenRequestStore`.** `public struct OpenRequestStore: Sendable` with:
  - `directory`
  - `static var applicationSupport`
  - `prepare() throws`
  - `submit(_:) throws`
  - `pending() -> [OpenRequest]`
  - `answer(_ id: String, with: OpenResult) throws`
  - `result(for id: String) throws -> OpenResult?`
  - `removeResult(for id: String) throws`
  - `withdraw(_ id: String) throws`
- **`FolderWatcher`.** `public final class FolderWatcher: @unchecked Sendable` with `init(directory: URL, onChange: @escaping @Sendable () -> Void) throws` and `stop()`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/OpenRequestStoreTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class OpenRequestStoreTests: XCTestCase {
    private var root: URL!
    private var store: OpenRequestStore { OpenRequestStore(directory: root.appendingPathComponent("open-requests")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ id: String, at seconds: TimeInterval = 0, task: OpenRequest.TaskOrigin? = nil) -> OpenRequest {
        OpenRequest(id: id, agent: .codex, folder: "/tmp/p", prompt: "say hi", tier: .light, task: task,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    func testASubmittedRequestIsPendingAsWritten() throws {
        let sent = request("R1", task: OpenRequest.TaskOrigin(fromAgent: .claude, fromSessionId: "S1"))
        try store.submit(sent)

        XCTAssertEqual(store.pending(), [sent])
    }

    func testPendingRequestsComeOldestFirst() throws {
        try store.submit(request("LATE", at: 5))
        try store.submit(request("EARLY", at: 1))

        XCTAssertEqual(store.pending().map(\.id), ["EARLY", "LATE"])
    }

    func testAnsweringWritesTheResultAndRemovesTheRequest() throws {
        try store.submit(request("R1"))
        try store.answer("R1", with: .opened(sessionId: "S9", message: "Opened Codex"))

        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertEqual(try store.result(for: "R1"), OpenResult(ok: true, sessionId: "S9", message: "Opened Codex"))
    }

    func testThereIsNoResultBeforeTheAnswer() throws {
        try store.submit(request("R1"))
        XCTAssertNil(try store.result(for: "R1"))
    }

    func testRemovingTheResultLeavesNothing() throws {
        try store.submit(request("R1"))
        try store.answer("R1", with: .refused("no"))
        try store.removeResult(for: "R1")

        XCTAssertNil(try store.result(for: "R1"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
    }

    func testAWithdrawnRequestIsNoLongerPending() throws {
        try store.submit(request("R1"))
        try store.withdraw("R1")
        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertNoThrow(try store.withdraw("R1"), "withdrawing twice is fine")
    }

    /// A request file that can't be read can never be answered: it is removed (and logged).
    func testAnUnreadableRequestIsRemoved() throws {
        try store.prepare()
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("BAD.json"))
        try store.submit(request("R1"))

        XCTAssertEqual(store.pending().map(\.id), ["R1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("BAD.json").path))
    }

    func testAnUnreadableResultThrows() throws {
        try store.prepare()
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("R1.result.json"))
        XCTAssertThrowsError(try store.result(for: "R1"))
    }

    func testTheFolderIsPrivateToTheUser() throws {
        try store.prepare()
        let mode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }
}
```

Create `Tests/LinkCKitTests/FolderWatcherTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class FolderWatcherTests: XCTestCase {
    func testAFileWrittenIntoTheFolderIsSeen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = expectation(description: "a change is reported")
        seen.assertForOverFulfill = false
        let watcher = try FolderWatcher(directory: folder) { seen.fulfill() }
        defer { watcher.stop() }

        try Data("{}".utf8).write(to: folder.appendingPathComponent("R1.json"), options: .atomic)

        wait(for: [seen], timeout: 2)
    }

    func testAFolderThatDoesNotExistCannotBeWatched() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try FolderWatcher(directory: missing) {})
    }
}
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "OpenRequestStoreTests|FolderWatcherTests"`. They fail to compile.

- [ ] **Step 3: Implement.** Create `Sources/LinkCKit/Command/OpenRequest.swift`:

```swift
import Foundation

/// A request from the `linkc` command for linkC to open an agent session. The command writes it into
/// `OpenRequestStore`'s folder, and linkC answers it with an `OpenResult` there.
public struct OpenRequest: Codable, Equatable, Sendable {
    /// Who wants the new session to carry a task: the agent the command ran under, and its linkC
    /// session when it runs in one.
    public struct TaskOrigin: Codable, Equatable, Sendable {
        public let fromAgent: AgentKind
        public let fromSessionId: String?

        public init(fromAgent: AgentKind, fromSessionId: String?) {
            self.fromAgent = fromAgent
            self.fromSessionId = fromSessionId
        }
    }

    public let id: String
    public let agent: AgentKind
    /// The folder the command ran in, canonical.
    public let folder: String
    public let prompt: String?
    public let tier: ModelTier?
    /// Set by `--task`: the session carries `prompt` as a task pinned to it.
    public let task: TaskOrigin?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, agent: AgentKind, folder: String, prompt: String?, tier: ModelTier?,
                task: TaskOrigin?, createdAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.folder = folder
        self.prompt = prompt
        self.tier = tier
        self.task = task
        self.createdAt = createdAt
    }
}

/// linkC's answer to an `OpenRequest`.
public struct OpenResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let sessionId: String?
    public let message: String

    public init(ok: Bool, sessionId: String?, message: String) {
        self.ok = ok
        self.sessionId = sessionId
        self.message = message
    }

    public static func opened(sessionId: String, message: String) -> OpenResult {
        OpenResult(ok: true, sessionId: sessionId, message: message)
    }

    public static func refused(_ message: String) -> OpenResult {
        OpenResult(ok: false, sessionId: nil, message: message)
    }
}

/// The folder the `linkc` command and linkC exchange requests and answers through: `<id>.json` is a
/// request, `<id>.result.json` its answer. Private to the user. Every file is written atomically, so a
/// reader never sees half of one.
public struct OpenRequestStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The folder in linkC's own Application Support folder.
    public static var applicationSupport: OpenRequestStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
            .appendingPathComponent("open-requests", isDirectory: true)
        return OpenRequestStore(directory: dir)
    }

    private static let resultSuffix = ".result.json"

    private func requestURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json", isDirectory: false) }
    private func resultURL(_ id: String) -> URL { directory.appendingPathComponent("\(id)\(Self.resultSuffix)", isDirectory: false) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Creates the folder, readable and writable by the user only.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func submit(_ request: OpenRequest) throws {
        try prepare()
        try Self.encoder.encode(request).write(to: requestURL(request.id), options: .atomic)
    }

    /// The requests not answered yet, oldest first. A request that can't be read is logged and removed:
    /// it could never be answered.
    public func pending() -> [OpenRequest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            NSLog("[linkC] open requests in %@ can't be listed — %@", directory.path, String(describing: error))
            return []
        }
        var requests: [OpenRequest] = []
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(Self.resultSuffix) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                requests.append(try Self.decoder.decode(OpenRequest.self, from: Data(contentsOf: url)))
            } catch {
                NSLog("[linkC] open request %@ can't be read, removing it — %@", name, String(describing: error))
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    NSLog("[linkC] open request %@ could not be removed — %@", name, String(describing: error))
                }
            }
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes the answer to `id` and removes the request.
    public func answer(_ id: String, with result: OpenResult) throws {
        try prepare()
        try Self.encoder.encode(result).write(to: resultURL(id), options: .atomic)
        try withdraw(id)
    }

    /// The answer to `id`, nil while there is none.
    public func result(for id: String) throws -> OpenResult? {
        let url = resultURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(OpenResult.self, from: Data(contentsOf: url))
    }

    public func removeResult(for id: String) throws {
        let url = resultURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes the request `id`, answered or given up on. Nothing to remove is fine.
    public func withdraw(_ id: String) throws {
        let url = requestURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
```

Create `Sources/LinkCKit/Command/FolderWatcher.swift`:

```swift
import Foundation

/// Calls `onChange` when an entry in `directory` is added, removed or renamed (kqueue through a dispatch
/// source on the folder). `onChange` runs on the watcher's own queue and can fire more than once per
/// change: callers only wake a loop.
public final class FolderWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    public struct OpenError: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String { "can't watch \(path): \(String(cString: strerror(code)))" }
    }

    public init(directory: URL, onChange: @escaping @Sendable () -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw OpenError(path: directory.path, code: errno) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "linkC.folder-watcher"))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    public func stop() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
```

- [ ] **Step 4: Run the tests.** Run `swift test --filter "OpenRequestStoreTests|FolderWatcherTests"`. All pass, and the build shows 0 warnings.

- [ ] **Step 5: Commit.** Tests first (`test(cli): the files the linkc command and linkC exchange`), then the implementation (`feat(cli): request and answer files for the linkc command, and a folder watcher`).

---

### Task 3: The command (LinkCKit)

**Files:**
- Create: `Sources/LinkCKit/Command/LinkCCommand.swift`
- Test: `Tests/LinkCKitTests/LinkCCommandTests.swift`

**Interfaces:**
- Consumes `OpenRequest`, `OpenResult` and `OpenRequestStore` (Task 2), plus `ProjectPath.canonical`.
- Produces `public enum LinkCCommand`, with:
  - `usage`;
  - `Invocation`, holding `agent`, `tier`, `task: Bool` and `prompt: String?`;
  - `Parsed` (`.help`, or `.open(Invocation)`);
  - `UsageError`;
  - `LaunchError`;
  - `Environment`;
  - `static func parse(_:) throws -> Parsed`;
  - `static func run(_:in:) -> (status: Int32, output: String)`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/LinkCCommandTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class LinkCCommandTests: XCTestCase {
    // MARK: - Arguments

    private func open(_ arguments: [String]) throws -> LinkCCommand.Invocation {
        guard case .open(let invocation) = try LinkCCommand.parse(arguments) else {
            throw XCTSkip("not an open invocation")
        }
        return invocation
    }

    private func usageError(_ arguments: [String]) -> String? {
        do {
            _ = try LinkCCommand.parse(arguments)
            return nil
        } catch let error as LinkCCommand.UsageError {
            return error.description
        } catch {
            return "unexpected \(error)"
        }
    }

    func testEveryAgentCanBeOpened() throws {
        for agent in [AgentKind.claude, .codex, .agy, .cursor, .grok] {
            XCTAssertEqual(try open([agent.rawValue]).agent, agent)
        }
    }

    func testThePromptIsTheRemainingWordsJoined() throws {
        XCTAssertEqual(try open(["codex", "fix", "the", "test"]).prompt, "fix the test")
        XCTAssertEqual(try open(["codex", "fix the test"]).prompt, "fix the test")
        XCTAssertNil(try open(["codex"]).prompt)
    }

    func testTierAndTaskAreRead() throws {
        let invocation = try open(["codex", "--tier", "deep", "--task", "hand", "off"])
        XCTAssertEqual(invocation.tier, .deep)
        XCTAssertTrue(invocation.task)
        XCTAssertEqual(invocation.prompt, "hand off")
        XCTAssertNil(try open(["codex"]).tier)
        XCTAssertFalse(try open(["codex"]).task)
    }

    func testADoubleDashMakesTheRestPromptWords() throws {
        XCTAssertEqual(try open(["codex", "--", "--task", "is", "text"]).prompt, "--task is text")
    }

    func testHelp() throws {
        XCTAssertEqual(try LinkCCommand.parse(["--help"]), .help)
        XCTAssertEqual(try LinkCCommand.parse(["codex", "-h"]), .help)
    }

    func testUsageErrors() {
        XCTAssertNotNil(usageError([]), "no agent")
        XCTAssertNotNil(usageError(["gpt"]), "unknown agent")
        XCTAssertNotNil(usageError(["shell"]), "a shell is not an agent")
        XCTAssertNotNil(usageError(["codex", "--fast"]), "unknown option")
        XCTAssertNotNil(usageError(["codex", "--tier"]), "a tier needs a value")
        XCTAssertNotNil(usageError(["codex", "--tier", "max"]), "unknown tier")
        XCTAssertNotNil(usageError(["codex", "--task"]), "a task needs a prompt")
    }

    // MARK: - Running

    private var root: URL!
    private var store: OpenRequestStore { OpenRequestStore(directory: root.appendingPathComponent("open-requests")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The outside world, with a fake linkC that answers (or not) the first time the command waits.
    private final class World: @unchecked Sendable {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var running = true
        var launched = false
        var answer: OpenResult?
        var caller: (agent: AgentKind, sessionId: String?)?
    }

    private func environment(_ world: World) -> LinkCCommand.Environment {
        let store = self.store
        return LinkCCommand.Environment(
            store: store,
            folder: root.path,
            caller: { world.caller },
            isLinkCRunning: { world.running },
            launchLinkC: { world.launched = true },
            now: { world.clock },
            sleep: { seconds in
                world.clock += seconds
                if let answer = world.answer, let request = store.pending().first {
                    try? store.answer(request.id, with: answer)
                }
            }
        )
    }

    func testAnOpenedSessionPrintsLinkCsMessageAndCleansUp() throws {
        let world = World()
        world.answer = .opened(sessionId: "S1", message: "Opened Codex in a linkC window (p).")
        let outcome = LinkCCommand.run(try open(["codex", "say", "hi"]), in: environment(world))

        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.output, "Opened Codex in a linkC window (p).")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [], "the answer is removed")
    }

    func testTheRequestCarriesTheAgentFolderPromptAndTier() throws {
        let world = World()
        _ = LinkCCommand.run(try open(["agy", "--tier", "light", "say", "hi"]), in: environment(world))

        let sent = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(sent.agent, .agy)
        XCTAssertEqual(sent.folder, ProjectPath.canonical(root.path))
        XCTAssertEqual(sent.prompt, "say hi")
        XCTAssertEqual(sent.tier, .light)
        XCTAssertNil(sent.task)
    }

    func testARefusalIsPrintedAsAnError() throws {
        let world = World()
        world.answer = .refused("no model configured for codex tier deep")
        let outcome = LinkCCommand.run(try open(["codex", "--tier", "deep"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.output, "linkc: no model configured for codex tier deep")
    }

    /// No answer within 20 seconds: the command says so and withdraws its request, so linkC never opens
    /// a window long after the user gave up.
    func testNoAnswerTimesOutAndWithdrawsTheRequest() throws {
        let world = World()
        let outcome = LinkCCommand.run(try open(["codex"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC did not answer within 20 seconds"), outcome.output)
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testLinkCIsStartedOnlyWhenItIsNotRunning() throws {
        let stopped = World()
        stopped.running = false
        stopped.answer = .opened(sessionId: "S1", message: "ok")
        _ = LinkCCommand.run(try open(["codex"]), in: environment(stopped))
        XCTAssertTrue(stopped.launched)

        let running = World()
        running.answer = .opened(sessionId: "S1", message: "ok")
        _ = LinkCCommand.run(try open(["codex"]), in: environment(running))
        XCTAssertFalse(running.launched)
    }

    func testATaskCarriesTheCallingAgent() throws {
        let world = World()
        world.caller = (.claude, "S7")
        _ = LinkCCommand.run(try open(["codex", "--task", "carry", "this"]), in: environment(world))

        let sent = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(sent.task, OpenRequest.TaskOrigin(fromAgent: .claude, fromSessionId: "S7"))
    }

    func testATaskWithNoCallingAgentIsRefused() throws {
        let world = World()
        let outcome = LinkCCommand.run(try open(["codex", "--task", "carry"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.output, "linkc: --task is for an agent handing off work; run without --task to open your own session.")
        XCTAssertTrue(store.pending().isEmpty, "nothing was asked of linkC")
    }

    func testAnAnswerThatCantBeReadIsAnError() throws {
        let world = World()
        let env = environment(world)
        var broken = env
        broken.sleep = { [store] seconds in
            world.clock += seconds
            if let request = store.pending().first {
                try? Data("not json".utf8).write(to: store.directory.appendingPathComponent("\(request.id).result.json"))
            }
        }
        let outcome = LinkCCommand.run(try open(["codex"]), in: broken)

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC's answer could not be read"), outcome.output)
    }
}
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter LinkCCommandTests`. They fail to compile.

- [ ] **Step 3: Implement.** Create `Sources/LinkCKit/Command/LinkCCommand.swift`:

```swift
import Foundation

/// The `linkc` command: `linkc <agent> [--tier T] [--task] [prompt ...]` asks linkC to open the agent in a
/// new window, in the current folder, with the prompt typed in. Parsing and running are here, with the
/// outside world injected; the executable only wires the real one in.
public enum LinkCCommand {
    public static let usage = """
        Usage: linkc <agent> [--tier light|standard|deep] [--task] [prompt ...]

        Opens <agent> in a new linkC window, in the current folder, with the prompt typed in.
          <agent>   claude, codex, agy, cursor or grok
          --tier    the model tier (default: the agent's default in linkC's Settings > Models)
          --task    for an agent handing off work: the new session carries the prompt as a task
                    the calling agent can follow (linkc_get_task) and close (linkc_close_worker)
        """

    /// The agents the command opens: every kind but the shell.
    static let agents: [AgentKind] = AgentKind.allCases.filter { $0 != .shell }

    public struct Invocation: Equatable, Sendable {
        public let agent: AgentKind
        public let tier: ModelTier?
        public let task: Bool
        public let prompt: String?
    }

    public enum Parsed: Equatable, Sendable {
        case help
        case open(Invocation)
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public struct LaunchError: Error, CustomStringConvertible {
        public let status: Int32
        public var description: String { "`open` exited with status \(status)" }
    }

    public static func parse(_ arguments: [String]) throws -> Parsed {
        if arguments.contains("--help") || arguments.contains("-h") { return .help }
        let names = agents.map(\.rawValue).joined(separator: ", ")
        var agent: AgentKind?
        var tier: ModelTier?
        var task = false
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                words.append(contentsOf: arguments[index...])
                break
            }
            if argument == "--task" {
                task = true
            } else if argument == "--tier" {
                guard index < arguments.count else { throw UsageError(description: "--tier needs a value: light, standard or deep") }
                guard let value = ModelTier(rawValue: arguments[index]) else {
                    throw UsageError(description: "unknown tier \"\(arguments[index])\": use light, standard or deep")
                }
                tier = value
                index += 1
            } else if (argument.hasPrefix("-") && agent == nil) || argument.hasPrefix("--") {
                throw UsageError(description: "unknown option \(argument)")
            } else if agent == nil {
                guard let kind = AgentKind(rawValue: argument), agents.contains(kind) else {
                    throw UsageError(description: "unknown agent \"\(argument)\": use \(names)")
                }
                agent = kind
            } else {
                words.append(argument)
            }
        }
        guard let agent else { throw UsageError(description: "name an agent: \(names)") }
        let prompt = words.isEmpty ? nil : words.joined(separator: " ")
        if task && prompt == nil { throw UsageError(description: "--task needs a prompt: the work to hand off") }
        return .open(Invocation(agent: agent, tier: tier, task: task, prompt: prompt))
    }

    /// What running the command needs from the outside world.
    public struct Environment {
        public var store: OpenRequestStore
        /// The folder the command runs in.
        public var folder: String
        /// The agent this command runs under, and its linkC session when it has one.
        public var caller: () -> (agent: AgentKind, sessionId: String?)?
        public var isLinkCRunning: () -> Bool
        public var launchLinkC: () throws -> Void
        public var now: () -> Date
        public var sleep: (TimeInterval) -> Void
        public var timeout: TimeInterval = 20
        public var pollInterval: TimeInterval = 0.1

        public init(store: OpenRequestStore, folder: String, caller: @escaping () -> (agent: AgentKind, sessionId: String?)?,
                    isLinkCRunning: @escaping () -> Bool, launchLinkC: @escaping () throws -> Void,
                    now: @escaping () -> Date, sleep: @escaping (TimeInterval) -> Void) {
            self.store = store
            self.folder = folder
            self.caller = caller
            self.isLinkCRunning = isLinkCRunning
            self.launchLinkC = launchLinkC
            self.now = now
            self.sleep = sleep
        }
    }

    /// Asks linkC to open `invocation` and waits for its answer. Returns the exit status and the line to
    /// print: on standard output for 0, on standard error otherwise.
    public static func run(_ invocation: Invocation, in env: Environment) -> (status: Int32, output: String) {
        var origin: OpenRequest.TaskOrigin?
        if invocation.task {
            guard let caller = env.caller() else {
                return (1, "linkc: --task is for an agent handing off work; run without --task to open your own session.")
            }
            origin = OpenRequest.TaskOrigin(fromAgent: caller.agent, fromSessionId: caller.sessionId)
        }
        let request = OpenRequest(agent: invocation.agent, folder: ProjectPath.canonical(env.folder),
                                  prompt: invocation.prompt, tier: invocation.tier, task: origin, createdAt: env.now())
        do {
            try env.store.submit(request)
        } catch {
            return (1, "linkc: the request for linkC could not be written — \(error)")
        }
        if !env.isLinkCRunning() {
            do {
                try env.launchLinkC()
            } catch {
                return (1, "linkc: linkC is not running and could not be started — \(error)")
            }
        }
        let deadline = env.now().addingTimeInterval(env.timeout)
        while true {
            let answer: OpenResult?
            do {
                answer = try env.store.result(for: request.id)
            } catch {
                return (1, "linkc: linkC's answer could not be read — \(error)")
            }
            if let answer {
                do {
                    try env.store.removeResult(for: request.id)
                } catch {
                    return (1, "linkc: \(answer.message) (its answer file could not be removed — \(error))")
                }
                return answer.ok ? (0, answer.message) : (1, "linkc: \(answer.message)")
            }
            if env.now() >= deadline {
                do {
                    try env.store.withdraw(request.id)
                } catch {
                    return (1, "linkc: linkC did not answer within \(Int(env.timeout)) seconds, and the request could not be withdrawn — \(error)")
                }
                return (1, "linkc: linkC did not answer within \(Int(env.timeout)) seconds. Is it running?")
            }
            env.sleep(env.pollInterval)
        }
    }
}
```

In `parse`, the condition `(argument.hasPrefix("-") && agent == nil) || argument.hasPrefix("--")` means:
- before the agent, any dash-word is an option;
- after the agent, only `--words` are options.

That way a prompt word like `-1` or `-v` after the agent stays a word.

- [ ] **Step 4: Run the tests.** Run `swift test --filter LinkCCommandTests`. All pass, and the build shows 0 warnings.

- [ ] **Step 5: Commit.** Tests first (`test(cli): parsing and running the linkc command`), then the implementation (`feat(cli): the linkc command asks linkC to open an agent and waits for its answer`).

---

### Task 4: linkC answers requests (LinkCKit)

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Create: `Sources/LinkCKit/App/AppCoordinator+Open.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorOpenTests.swift` (new), and `Tests/LinkCKitTests/AppCoordinatorTickerTests.swift` (one wiring test)

**Interfaces:**
- **Consumes:**
  - Tasks 1 and 2.
  - `newSession(cwd:agent:mode:tier:select:asWorker:)`.
  - `terminals.sendInput(sessionId:text:)`, `recordInjection(sessionId:text:startsWork:)`, `isIdle(_:)` and `injectionGapElapsed(sessionId:)`.
  - `deliverySettle`, `pasteNegotiationTimeout`, `now()` and `sweepTicker`.
- **Produces:**
  - `AppCoordinator` init parameter `openRequests: OpenRequestStore? = nil`, right after `mcpWorkspaces:`.
  - `public var onCommandSessionOpened: ((String) -> Void)?`
  - `func handleOpenRequests()`, `func open(_ request: OpenRequest) -> OpenResult` and `func typeOpeningPrompts()`.
  - `var openingPrompts: [String: OpeningPrompt]`.
  - `static let openRequestMaxAge: TimeInterval = 60`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/AppCoordinatorOpenTests.swift`. Its harness is a copy of `AppCoordinatorRelayTests`' `makeCoordinator`, using the same mock agent script, plus the request store:

```swift
import XCTest
@testable import LinkCKit

@MainActor
final class AppCoordinatorOpenTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-open-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var requests: OpenRequestStore { OpenRequestStore(directory: tempDir.appendingPathComponent("open-requests")) }
    private var folder: String { ProjectPath.canonical(tempDir.path) }

    private func makeCoordinator(models: AgentModelSettings = .seeded,
                                 now: @escaping @MainActor @Sendable () -> Date = Date.init) -> AppCoordinator {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: script.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in script.path },
            modelSettings: { models },
            deliverySettle: 0,
            injectionGap: 0,
            now: now,
            openRequests: requests,
            isWatching: { _ in false }
        )
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func request(_ agent: AgentKind = .codex, prompt: String? = nil, task: OpenRequest.TaskOrigin? = nil,
                         folder: String? = nil, createdAt: Date = Date()) -> OpenRequest {
        OpenRequest(agent: agent, folder: folder ?? self.folder, prompt: prompt, tier: nil, task: task, createdAt: createdAt)
    }

    private func stopAll(_ coordinator: AppCoordinator) {
        coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
        coordinator.shutdown()
    }

    func testARequestOpensTheAgentInItsFolderAndAnswers() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        var opened: [String] = []
        coordinator.onCommandSessionOpened = { opened.append($0) }
        let sent = request()
        try requests.submit(sent)

        coordinator.handleOpenRequests()

        let session = try XCTUnwrap(coordinator.store.sessions.first)
        XCTAssertEqual(session.agentKind, .codex)
        XCTAssertEqual(session.cwd, folder)
        XCTAssertFalse(session.isWorker, "opened by the user: their session")
        XCTAssertEqual(opened, [session.id])
        let answer = try XCTUnwrap(requests.result(for: sent.id))
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(answer.sessionId, session.id)
        XCTAssertEqual(answer.message, "Opened Codex in a linkC window (\(URL(fileURLWithPath: folder).lastPathComponent)).")
        XCTAssertTrue(requests.pending().isEmpty)
    }

    func testAnOldRequestIsRefusedAndOpensNothing() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        let sent = request(createdAt: Date().addingTimeInterval(-120))
        try requests.submit(sent)

        coordinator.handleOpenRequests()

        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        XCTAssertEqual(try requests.result(for: sent.id)?.ok, false)
    }

    func testAFolderThatDoesNotExistIsRefused() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        let sent = request(folder: tempDir.appendingPathComponent("nope").path)
        try requests.submit(sent)

        coordinator.handleOpenRequests()

        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        let answer = try XCTUnwrap(requests.result(for: sent.id))
        XCTAssertFalse(answer.ok)
        XCTAssertTrue(answer.message.contains("does not exist"), answer.message)
    }

    func testATierWithNoModelIsRefusedWithTheReason() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .grok, tier: .standard)
        let coordinator = makeCoordinator(models: models)
        defer { stopAll(coordinator) }
        let sent = OpenRequest(agent: .grok, folder: folder, prompt: nil, tier: .standard, task: nil)
        try requests.submit(sent)

        coordinator.handleOpenRequests()

        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        let answer = try XCTUnwrap(requests.result(for: sent.id))
        XCTAssertFalse(answer.ok)
        XCTAssertTrue(answer.message.contains("no model configured"), answer.message)
    }

    /// The prompt goes in once the agent is ready for it, and only once.
    func testThePromptIsTypedOnceWhenTheAgentIsReady() async throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        try requests.submit(request(prompt: "say hi"))
        coordinator.handleOpenRequests()
        let session = try XCTUnwrap(coordinator.store.sessions.first)
        let terminal = try XCTUnwrap(coordinator.terminals.session(id: session.id))

        coordinator.typeOpeningPrompts()
        XCTAssertFalse(terminal.recentOutput(lines: 10).contains("say hi"), "the agent is still starting")

        coordinator.store.updateState(id: session.id, to: .ready)
        let ready = try await waitUntil { terminal.acceptsPaste }
        XCTAssertTrue(ready, "the mock agent never negotiated paste")
        coordinator.typeOpeningPrompts()
        coordinator.store.updateState(id: session.id, to: .ready)
        coordinator.typeOpeningPrompts()

        let typed = try await waitUntil { terminal.recentOutput(lines: 10).contains("say hi") }
        XCTAssertTrue(typed, "the prompt never reached the agent: \(terminal.recentOutput(lines: 10))")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(terminal.recentOutput(lines: 10).components(separatedBy: "say hi").count - 1, 1, "typed once")
        XCTAssertTrue(coordinator.openingPrompts.isEmpty)
    }

    func testATaskRequestOpensAWorkerCarryingATaskPinnedToIt() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        try requests.submit(request(prompt: "carry this", task: OpenRequest.TaskOrigin(fromAgent: .claude, fromSessionId: "D1")))

        coordinator.handleOpenRequests()

        let session = try XCTUnwrap(coordinator.store.sessions.first)
        XCTAssertTrue(session.isWorker)
        let task = try XCTUnwrap(InboxStore(workspaceRoot: folder).load().tasks.first)
        XCTAssertEqual(task.toAgent, .codex)
        XCTAssertEqual(task.fromAgent, .claude)
        XCTAssertEqual(task.fromSessionId, "D1")
        XCTAssertEqual(task.prompt, "carry this")
        XCTAssertEqual(task.targetSessionId, session.id)
        XCTAssertTrue(coordinator.openingPrompts.isEmpty, "a task brief is delivered by the relay, not typed as a prompt")
    }
}
```

`InboxStore.load()` reads the inbox. If the store's read API has another name (`snapshot`), use that one.

In `AppCoordinatorTickerTests.swift`:
- add a parameter `openRequests: OpenRequestStore? = nil` to `makeCoordinator`, and pass `openRequests: openRequests,` right after `mcpWorkspaces: mcpWorkspaces,`;
- add this test:

```swift
    /// The sweep answers the `linkc` command: a request waiting when linkC starts opens its session.
    func testTheSweepAnswersARequestFromTheLinkCCommand() async throws {
        let requests = OpenRequestStore(directory: tempDir.appendingPathComponent("open-requests"))
        let coordinator = try makeCoordinator(openRequests: requests)
        defer {
            coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
            coordinator.shutdown()
        }
        let sent = OpenRequest(agent: .codex, folder: ProjectPath.canonical(tempDir.path), prompt: nil, tier: nil, task: nil)
        try requests.submit(sent)

        try coordinator.start()

        let answered = try await waitUntil { (try? requests.result(for: sent.id)) != nil }
        XCTAssertTrue(answered, "the sweep never answered the request")
        XCTAssertEqual(coordinator.store.sessions.first?.agentKind, .codex)
    }
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "AppCoordinatorOpenTests|AppCoordinatorTickerTests"`. They fail to compile.

- [ ] **Step 3: Implement.** In `AppCoordinator.swift`:
  - **The store.** Add the property `private let openRequests: OpenRequestStore?` (doc: "Where the `linkc` command leaves its requests; nil turns the command off"). Add the init parameter `openRequests: OpenRequestStore? = nil,` right after `mcpWorkspaces:`, and assign it.
  - **The app's convenience init** passes `openRequests: .applicationSupport,` right before `isWatching:`.
  - **New state:**
    - `var openingPrompts: [String: OpeningPrompt] = [:]`
    - `private var openRequestWatcher: FolderWatcher?`
    - `public var onCommandSessionOpened: ((String) -> Void)?`, documented as: "Told the id of a session the `linkc` command opened, so the app can give it a window."
  - **`start()`.** After the `sweepTicker = ticker` / `ticker.start()` lines, add:
    ```swift
    if let openRequests {
        do {
            try openRequests.prepare()
            openRequestWatcher = try FolderWatcher(directory: openRequests.directory) { [weak self] in
                Task { @MainActor in self?.sweepTicker?.wake() }
            }
        } catch {
            NSLog("[linkC] the linkc command's request folder %@ can't be watched; requests are read on each sweep — %@",
                  openRequests.directory.path, String(describing: error))
        }
    }
    ```
  - **`shutdown()`.** After `inboxWatcher = nil`, add `openRequestWatcher?.stop()` and `openRequestWatcher = nil`.
  - **`sweepTick()`.** After the `for folder in serverOnlyFolders.sorted() { ... }` loop, add `handleOpenRequests()` and `typeOpeningPrompts()`.
  - **`sweepInterval()`.** Pass `hasRelayWork: !relayWork.isEmpty || !openingPrompts.isEmpty`, so a waiting prompt keeps the fast cadence.

Create `Sources/LinkCKit/App/AppCoordinator+Open.swift`:

```swift
import Foundation

/// A prompt the `linkc` command asked for, waiting for its agent to be ready.
struct OpeningPrompt: Equatable {
    let text: String
    /// When the session was opened: a prompt still waiting `pasteNegotiationTimeout` later is dropped.
    let since: Date
}

extension AppCoordinator {
    /// How old a request may be and still open a session: an older one was left while linkC was not running.
    static let openRequestMaxAge: TimeInterval = 60

    /// Answers every request the `linkc` command left: opens its session, or says why not.
    func handleOpenRequests() {
        guard let openRequests else { return }
        for request in openRequests.pending() {
            let result = open(request)
            do {
                try openRequests.answer(request.id, with: result)
            } catch {
                NSLog("[linkC] open request %@: the answer could not be written — %@", request.id, String(describing: error))
            }
        }
    }

    /// Opens `request`'s agent in its folder: a worker carrying a task pinned to it when the request
    /// carries one, else the user's own session with its prompt waiting to be typed.
    func open(_ request: OpenRequest) -> OpenResult {
        let age = now().timeIntervalSince(request.createdAt)
        guard age <= Self.openRequestMaxAge else {
            return .refused("the request is \(Int(age)) seconds old (linkC was not running to see it in time); run the command again")
        }
        guard request.agent != .shell else { return .refused("a shell is not an agent") }
        let folder = ProjectPath.canonical(request.folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .refused("the folder \(request.folder) does not exist")
        }
        if request.task != nil, request.prompt == nil {
            return .refused("a task needs a prompt")
        }
        let session: Session
        do {
            session = try newSession(cwd: folder, agent: request.agent, tier: request.tier, select: false,
                                     asWorker: request.task != nil)
        } catch {
            return .refused("\(request.agent.displayName) could not start: \(error)")
        }
        if let origin = request.task, let prompt = request.prompt {
            do {
                _ = try InboxStore(workspaceRoot: folder).createTask(
                    from: origin.fromAgent, to: request.agent, fromSessionId: origin.fromSessionId,
                    targetSessionId: session.id, prompt: prompt, files: [])
            } catch {
                stopSession(session.id)
                return .refused("the task could not be recorded: \(error)")
            }
        } else if let prompt = request.prompt {
            openingPrompts[session.id] = OpeningPrompt(text: prompt, since: now())
        }
        onCommandSessionOpened?(session.id)
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return .opened(sessionId: session.id, message: "Opened \(request.agent.displayName) in a linkC window (\(name)).")
    }

    /// Types each waiting prompt into its session once the agent is ready for it: idle, paste negotiated
    /// and settled, outside the injection gap. The same readiness a task brief waits for. A prompt whose
    /// session ended, or whose agent is not ready within `pasteNegotiationTimeout`, is dropped and logged.
    func typeOpeningPrompts() {
        for (id, prompt) in openingPrompts {
            guard let session = store.session(id: id), session.state != .ended, let terminal = terminals.session(id: id) else {
                openingPrompts[id] = nil
                NSLog("[linkC] the linkc prompt for %@ was not typed: its session ended first", id)
                continue
            }
            let settled = terminal.acceptsPaste
                && (terminal.pasteReadySince.map { now().timeIntervalSince($0) >= deliverySettle } ?? false)
            guard isIdle(session.state), injectionGapElapsed(sessionId: id), settled else {
                if now().timeIntervalSince(prompt.since) > Self.pasteNegotiationTimeout {
                    openingPrompts[id] = nil
                    NSLog("[linkC] the linkc prompt for %@ was not typed: %@ was not ready for it within %.0fs",
                          id, session.agentKind.displayName, Self.pasteNegotiationTimeout)
                }
                continue
            }
            openingPrompts[id] = nil
            if terminals.sendInput(sessionId: id, text: prompt.text) {
                recordInjection(sessionId: id, text: prompt.text, startsWork: true)
                store.updateState(id: id, to: .working)
            } else {
                NSLog("[linkC] the linkc prompt for %@ did not reach its terminal", id)
            }
        }
    }
}
```

`openRequests`, `deliverySettle`, `now` and `recordInjection` must be reachable from the extension. If any is `private` in `AppCoordinator.swift`, make it internal (drop `private`); don't make it public. `createTask`'s parameter order is the one Task 1 produced: `fromSessionId`, then `targetSessionId`, then `tier`. Adjust the call if the labels differ.

- [ ] **Step 4: Run the tests.** Run `swift test --filter "AppCoordinatorOpenTests|AppCoordinatorTickerTests|AppCoordinatorRelayTests"`. All pass, and the build shows 0 warnings.

- [ ] **Step 5: Commit.** Tests first (`test(cli): linkC opens the session a linkc request asks for`), then the implementation (`feat(cli): linkC answers linkc requests and types the prompt once the agent is ready`).

---

### Task 5: The executable, install and window (app target)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/linkc-cli/main.swift`
- Modify: `build-app.sh`
- Modify: `Sources/linkc/LinkCApp.swift` (coordinator wiring, around the `AppCoordinator(` construction near line 226)
- Modify: `README.md`

The app target and the executables have no unit tests. Check them by building with no warnings, running the full suite, reading the code, and running `swift run linkc-cli --help` plus one parse error. Never run the built CLI for real: a real run would ask the user's running linkC to open a window.

- [ ] **Step 1: `Package.swift`.** Add the product `.executable(name: "linkc-cli", targets: ["linkc-cli"]),` after the `linkc-mcp` product. Then add this target after the `linkc-mcp` target:

```swift
        .executableTarget(
            name: "linkc-cli",
            dependencies: ["LinkCKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

- [ ] **Step 2: `Sources/linkc-cli/main.swift`:**

```swift
import AppKit
import Foundation
import LinkCKit

let parsed: LinkCCommand.Parsed
do {
    parsed = try LinkCCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("linkc: \(error)\n\n\(LinkCCommand.usage)\n".utf8))
    exit(2)
}
guard case .open(let invocation) = parsed else {
    print(LinkCCommand.usage)
    exit(0)
}

let bundleIdentifier = "com.linkc.app"
let environment = LinkCCommand.Environment(
    store: .applicationSupport,
    folder: FileManager.default.currentDirectoryPath,
    caller: {
        // The agent this command runs under (an agent's shell tool starts a shell, which starts this).
        guard let found = ProcessSnooper.detectAgent(inAncestorsOf: getppid()) else { return nil }
        return (found.agent, ProcessInfo.processInfo.environment["LINKC_SESSION"])
    },
    isLinkCRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty },
    launchLinkC: {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleIdentifier]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw LinkCCommand.LaunchError(status: open.terminationStatus) }
    },
    now: Date.init,
    sleep: { Thread.sleep(forTimeInterval: $0) }
)
let outcome = LinkCCommand.run(invocation, in: environment)
let output = outcome.status == 0 ? FileHandle.standardOutput : FileHandle.standardError
output.write(Data((outcome.output + "\n").utf8))
exit(outcome.status)
```

- [ ] **Step 3: `build-app.sh`.**
  - After the `MCP_BIN=` line, add `CLI_BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/linkc-cli"`.
  - After `cp "$MCP_BIN" ...`, add `cp "$CLI_BIN" "$APP/Contents/MacOS/linkc-cli"`.
  - After the `ln -sf ... linkc-mcp` line, add `ln -sf "$APP/Contents/MacOS/linkc-cli" "$HOME/.local/bin/linkc"`.
  - If the script prints a summary of what it installed, add the `linkc` link to it.

- [ ] **Step 4: Wire the window** (`Sources/linkc/LinkCApp.swift`). Right after the `let coordinator = AppCoordinator(...)` construction (and its existing post-construction setup), add:

```swift
            // A session the `linkc` command opened gets its own window, and linkC comes forward with it.
            coordinator.onCommandSessionOpened = { [weak self] id in
                guard let self else { return }
                self.tearOff(.terminal(id), at: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
```

`tearOff` is `AppModel`'s (`AppModel+TornOff.swift`). It refuses a terminal that isn't live, and `liveTerminalIDs` reads `coordinator.store.sessions` directly, so the session just created is live. Place the closure where `self` is the `AppModel`. If this spot is inside a closure where `self` is something else, set it from the `AppModel` method that stores `coordinator`.

- [ ] **Step 5: README.** After the paragraph that PR A added (about agents started outside linkC), add a short subsection:

```markdown
### Opening an agent from a terminal

`linkc <agent> "prompt"` (installed by `build-app.sh` at `~/.local/bin/linkc`) opens claude, codex,
agy, cursor or grok in a new linkC window, in the folder you ran it from, with the prompt typed in.
Exiting the agent closes the window. `--tier light|standard|deep` picks the model tier. An agent can
add `--task` to hand the prompt off as a task: the new session is a worker it can follow with
`linkc_get_task` and close with `linkc_close_worker`. If linkC isn't running, the command starts it.
```

- [ ] **Step 6: Verify.**
  - `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing.
  - The full suite reports 0 failures: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | sort -k2 -n | tail -1`.
  - `swift run linkc-cli --help` prints the usage and exits 0.
  - `swift run linkc-cli gpt; echo $?` prints `linkc: unknown agent "gpt": use claude, codex, agy, cursor, grok`, then the usage, then `2`.
  - `bash -n build-app.sh` reports no syntax errors. Do not run `build-app.sh`; the controller runs it.

- [ ] **Step 7: Commit.** `feat(cli): the linkc executable, its install, and a window for the session it opens`
