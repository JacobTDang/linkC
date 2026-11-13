import XCTest
import os
@testable import LinkCKit

@MainActor
final class ModelListRefresherTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var cache: ModelListCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-model-list-refresher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache = ModelListCache(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _durations: [Duration] = []
        var durations: [Duration] { lock.lock(); defer { lock.unlock() }; return _durations }
        func record(_ duration: Duration) {
            lock.lock(); _durations.append(duration); lock.unlock()
        }
    }

    private final class RunLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _agents: [AgentKind] = []
        var agents: [AgentKind] { lock.lock(); defer { lock.unlock() }; return _agents }
        func record(_ agent: AgentKind) { lock.lock(); _agents.append(agent); lock.unlock() }
        func count(_ agent: AgentKind) -> Int { agents.filter { $0 == agent }.count }
    }

    private nonisolated static let agyOutput = "Fetching available models...\ngemini-3.8-flash-medium\tFlash\n"
    private nonisolated static let cursorOutput = "Available models\n\nauto - Auto\ngrok-4.7-low - Grok 4.7  Low\n"
    private nonisolated static let openCodeOutput = "opencode/big-pickle\nopencode/claude-sonnet-5\n"
    private nonisolated static let kiloOutput = "kilo/kilo-auto/free\nkilo/anthropic/claude-sonnet-5\n"

    /// A runner that answers each agent with its usual listing and records what it was asked.
    private func scripted(_ log: RunLog) -> ModelListRefresher.Runner {
        { agent in
            log.record(agent)
            switch agent {
            case .agy: return Self.agyOutput
            case .cursor, .grok: return Self.cursorOutput
            case .opencode: return Self.openCodeOutput
            case .kilo: return Self.kiloOutput
            default: throw LinkCError.process("unexpected agent \(agent)")
            }
        }
    }

    func testRefresherWritesParsedLists() async throws {
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                switch agent {
                case .agy:
                    return "Fetching available models...\ngemini-3.8-flash-medium\tFlash\n"
                case .cursor, .grok:
                    // Grok reuses Cursor's listing; the refresher filters with ModelListParser.grok.
                    return "Available models\n\nauto - Auto\ngrok-4.7-low - Grok 4.7  Low\n"
                case .opencode:
                    return "opencode/big-pickle\nopencode/claude-sonnet-5\n"
                case .kilo:
                    return "kilo/kilo-auto/free\nkilo/anthropic/claude-sonnet-5\n"
                case .crush:
                    return "openrouter/nvidia/nemotron-3.5-lightning:free\nopenrouter/anthropic/claude-opus-4.5\n"
                default:
                    XCTFail("unexpected agent \(agent)")
                    return ""
                }
            },
            sleep: { _ in },
            interval: .seconds(21_600))

        await refresher.refreshNow()

        let lists = try cache.read()
        XCTAssertEqual(lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"])
        XCTAssertNil(lists[.agy]?.error)
        XCTAssertNotNil(lists[.agy]?.fetchedAt)
        XCTAssertEqual(lists[.cursor]?.models.map(\.id), ["auto", "grok-4.7-low"])
        XCTAssertEqual(lists[.grok]?.models.map(\.id), ["grok-4.7-low"])
        XCTAssertEqual(lists[.opencode]?.models.map(\.id), ["opencode/big-pickle"])
        XCTAssertEqual(lists[.kilo]?.models.map(\.id), ["kilo/kilo-auto/free"])
        XCTAssertEqual(lists[.crush]?.models.map(\.id), ["openrouter/nvidia/nemotron-3.5-lightning:free"])
        XCTAssertNil(lists[.claude])
        XCTAssertNil(lists[.codex])
    }

    func testFailedRunKeepsOldModelsAndRecordsError() async throws {
        try cache.write([
            .agy: AgentModelList(
                models: [ListedModel(id: "gemini-3.8-flash-medium", name: "Flash")],
                fetchedAt: Date(timeIntervalSince1970: 1),
                error: nil),
        ])
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                if agent == .agy { throw LinkCError.process("agy offline") }
                return ""
            },
            sleep: { _ in })

        await refresher.refreshNow()

        let lists = try cache.read()
        XCTAssertEqual(lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"])
        XCTAssertEqual(lists[.agy]?.error, "agy offline")
        XCTAssertEqual(lists[.agy]?.fetchedAt, Date(timeIntervalSince1970: 1))
    }

    func testScheduleIsSixHours() async throws {
        let sleeps = SleepLog()
        let gate = OSAllocatedUnfairLock(initialState: 0)
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { _ in "" },
            sleep: { duration in
                sleeps.record(duration)
                gate.withLock { $0 += 1 }
                // End the loop after the first scheduled sleep is observed.
                if sleeps.durations.count >= 1 {
                    throw CancellationError()
                }
            },
            interval: .seconds(21_600))

        let task = Task { await refresher.start() }
        for _ in 0..<100 {
            if sleeps.durations.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = await task.result

        XCTAssertEqual(sleeps.durations.first, .seconds(21_600))
        XCTAssertEqual(ModelListRefresher.defaultInterval, .seconds(21_600))
    }

    /// The 6-hour schedule loops: it refreshes, sleeps, refreshes again, until it is cancelled.
    func testScheduleRefreshesAgainAfterEachSleep() async throws {
        let log = RunLog()
        let sleeps = SleepLog()
        let refresher = ModelListRefresher(
            cache: cache,
            runner: scripted(log),
            sleep: { duration in
                sleeps.record(duration)
                if sleeps.durations.count >= 2 { throw CancellationError() }
            },
            interval: .seconds(21_600))

        await refresher.start()

        XCTAssertEqual(sleeps.durations, [.seconds(21_600), .seconds(21_600)])
        XCTAssertEqual(log.count(.agy), 2, "one refresh before each sleep")
        XCTAssertEqual(log.count(.opencode), 2)
    }

    /// Only cancellation ends the schedule. Any other failure of the sleep is logged and the loop goes on.
    func testAFailedSleepDoesNotEndTheSchedule() async throws {
        struct SleepBroke: Error {}
        let log = RunLog()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let refresher = ModelListRefresher(
            cache: cache,
            runner: scripted(log),
            sleep: { _ in
                let call = calls.withLock { n -> Int in n += 1; return n }
                if call == 1 { throw SleepBroke() }
                throw CancellationError()
            })

        await refresher.start()

        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(log.count(.agy), 2, "the loop refreshed again after the sleep that broke")
    }

    /// `cursor-agent models` runs once for Cursor and Grok together.
    func testCursorsListingServesGrokWithoutASecondRun() async throws {
        let log = RunLog()
        let refresher = ModelListRefresher(cache: cache, runner: scripted(log), sleep: { _ in })

        await refresher.refreshNow()

        XCTAssertEqual(log.count(.cursor), 1)
        XCTAssertEqual(log.count(.grok), 0, "grok reads Cursor's listing")
        let lists = try cache.read()
        XCTAssertEqual(lists[.grok]?.models.map(\.id), ["grok-4.7-low"])
        XCTAssertEqual(lists[.cursor]?.models.map(\.id), ["auto", "grok-4.7-low"])
    }

    func testAFailedCursorRunFailsBothCursorAndGrok() async throws {
        let log = RunLog()
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                log.record(agent)
                if agent == .cursor { throw LinkCError.process("cursor-agent offline") }
                return Self.agyOutput
            },
            sleep: { _ in })

        await refresher.refreshNow()

        XCTAssertEqual(log.count(.cursor), 1)
        let lists = try cache.read()
        XCTAssertEqual(lists[.cursor]?.error, "cursor-agent offline")
        XCTAssertEqual(lists[.grok]?.error, "cursor-agent offline")
    }

    /// A CLI that prints text but no models (an error line, a changed format) must not wipe the
    /// last good list or pass for a good listing.
    func testAListingWithNoModelsKeepsTheLastGoodListAndRecordsAnError() async throws {
        try cache.write([
            .agy: AgentModelList(
                models: [ListedModel(id: "gemini-3.8-flash-medium", name: "Flash")],
                fetchedAt: Date(timeIntervalSince1970: 1), error: nil),
        ])
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                switch agent {
                case .agy: return "Error: not logged in\n"
                case .cursor, .grok: return Self.cursorOutput
                case .opencode: return Self.openCodeOutput
                case .kilo: return Self.kiloOutput
                default: return Self.openCodeOutput
                }
            },
            sleep: { _ in })

        await refresher.refreshNow()

        let lists = try cache.read()
        XCTAssertEqual(lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"], "the last good list is kept")
        XCTAssertEqual(lists[.agy]?.error, "agy models listed nothing: Error: not logged in")
        XCTAssertEqual(lists[.agy]?.fetchedAt, Date(timeIntervalSince1970: 1))
    }

    /// The same rule for every agent: Grok finding no `grok-` model in Cursor's list, OpenCode/Kilo no free one.
    func testEveryAgentsEmptyParseIsAnError() async throws {
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                switch agent {
                case .agy: return Self.agyOutput
                case .cursor, .grok: return "Available models\n\nauto - Auto\n"
                case .opencode: return "opencode/claude-sonnet-5\n"
                case .kilo: return "kilo/anthropic/claude-sonnet-5\n"
                default: return Self.openCodeOutput
                }
            },
            sleep: { _ in })

        await refresher.refreshNow()

        let lists = try cache.read()
        XCTAssertNil(lists[.agy]?.error)
        XCTAssertNil(lists[.cursor]?.error)
        XCTAssertEqual(lists[.grok]?.error, "grok models listed nothing: Available models")
        XCTAssertEqual(lists[.opencode]?.error, "opencode models listed nothing: opencode/claude-sonnet-5")
        XCTAssertEqual(lists[.kilo]?.error, "kilo models listed nothing: kilo/anthropic/claude-sonnet-5")
        XCTAssertEqual(lists[.grok]?.models, [])
    }

    func testABlankListingIsAnErrorToo() async throws {
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                switch agent {
                case .agy: return "  \n"
                case .opencode: return Self.openCodeOutput
                case .kilo: return Self.kiloOutput
                default: return Self.cursorOutput
                }
            },
            sleep: { _ in })

        await refresher.refreshNow()

        XCTAssertEqual(try cache.read()[.agy]?.error, "agy models listed nothing: (no output)")
    }

    /// An unreadable cache is reported, and does not turn the last known lists into empty ones.
    func testAnUnreadableCacheIsReportedAndKeepsWhatWasKnown() async throws {
        let log = RunLog()
        let flag = OSAllocatedUnfairLock(initialState: false)
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                log.record(agent)
                if flag.withLock({ $0 }) { throw LinkCError.process("\(agent.rawValue) offline") }
                return Self.scriptedListing(for: agent)
            },
            sleep: { _ in })
        await refresher.refreshNow()
        XCTAssertEqual(refresher.lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"])
        XCTAssertNil(refresher.cacheReadError)

        try "{ this is not json".write(to: cache.url, atomically: true, encoding: .utf8)
        flag.withLock { $0 = true }
        await refresher.refreshNow()

        XCTAssertNotNil(refresher.cacheReadError, "a corrupt cache is reported")
        XCTAssertEqual(refresher.lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"],
                       "what was known is kept, not replaced by an empty list")
        let error = try XCTUnwrap(refresher.lists[.agy]?.error)
        XCTAssertTrue(error.contains("agy offline"), error)
        XCTAssertTrue(error.contains("unreadable"), "the agent's error says its cache was unreadable: \(error)")
        // The unreadable file is moved aside, not silently overwritten.
        let kept = try String(contentsOf: cache.url.appendingPathExtension("corrupt"), encoding: .utf8)
        XCTAssertEqual(kept, "{ this is not json")
        XCTAssertEqual(try cache.read()[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"])
    }

    /// A cache that cannot be written is reported, and the lists are still served from memory.
    func testACacheThatCannotBeWrittenIsReported() async throws {
        let blocker = dir.appendingPathComponent("not-a-folder")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let unwritable = ModelListCache(directory: blocker.appendingPathComponent("linkC"))
        let refresher = ModelListRefresher(cache: unwritable, runner: scripted(RunLog()), sleep: { _ in })

        await refresher.refreshNow()

        let problem = try XCTUnwrap(refresher.cacheWriteError)
        XCTAssertTrue(problem.contains("model-lists.json"), problem)
        XCTAssertEqual(refresher.lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"],
                       "the app still has the lists it just fetched")
    }

    /// Settings reads `lists` and redraws when a refresh ends: the refresher is observable.
    func testTheListsAreObservable() async throws {
        let refresher = ModelListRefresher(cache: cache, runner: scripted(RunLog()), sleep: { _ in })
        XCTAssertTrue(refresher.lists.isEmpty)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = refresher.lists
        } onChange: {
            changed.withLock { $0 = true }
        }

        await refresher.refreshNow()

        XCTAssertTrue(changed.withLock { $0 }, "a view reading `lists` is told when a refresh ends")
        XCTAssertEqual(refresher.lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"])
        XCTAssertNil(refresher.cacheProblem)
    }

    /// What the cache held when the app started is there before the first refresh.
    func testTheListsStartFromTheCache() throws {
        try cache.write([.agy: AgentModelList(models: [ListedModel(id: "gemini-3.8-flash-low", name: "Low")],
                                             fetchedAt: Date(timeIntervalSince1970: 5), error: nil)])
        let refresher = ModelListRefresher(cache: cache, runner: scripted(RunLog()), sleep: { _ in })
        XCTAssertEqual(refresher.lists[.agy]?.models.map(\.id), ["gemini-3.8-flash-low"])
    }

    /// Refreshes do not overlap: a second one asked for while one runs does nothing.
    func testAnOverlappingRefreshDoesNotRunAgain() async throws {
        let log = RunLog()
        let release = OSAllocatedUnfairLock(initialState: false)
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                log.record(agent)
                while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
                return Self.scriptedListing(for: agent)
            },
            sleep: { _ in })

        let first = Task { await refresher.refreshNow() }
        for _ in 0..<200 where log.agents.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(refresher.isRefreshing)
        await refresher.refreshNow()   // returns at once: one is running
        XCTAssertEqual(log.agents, [.agy], "the second call ran nothing")
        release.withLock { $0 = true }
        await first.value

        XCTAssertFalse(refresher.isRefreshing)
        XCTAssertEqual(log.count(.agy), 1)
        XCTAssertEqual(log.count(.opencode), 1)
        XCTAssertEqual(log.count(.kilo), 1)
    }

    private nonisolated static func scriptedListing(for agent: AgentKind) -> String {
        switch agent {
        case .agy: return agyOutput
        case .opencode: return openCodeOutput
        case .kilo: return kiloOutput
        default: return cursorOutput
        }
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    func testSwitchModelRefusesAnIdNotInAvailableAndListsThem() throws {
        try cache.write([
            .claude: AgentModelList(
                models: [
                    ListedModel(id: "haiku", name: "haiku"),
                    ListedModel(id: "sonnet", name: "sonnet"),
                    ListedModel(id: "opus", name: "opus"),
                ],
                fetchedAt: Date(),
                error: nil),
        ])
        let settingsDir = dir.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: settingsDir.appendingPathComponent("user-settings.json"),
            manifestDir: settingsDir.appendingPathComponent("manifest"),
            modelSettings: { .seeded },
            modelLists: { try ModelListCache(directory: self.dir).read() },
            isWatching: { _ in false })
        _ = coordinator.store.create(cwd: dir.path, title: "claude", id: "s1", agentKind: .claude)
        coordinator.store.updateState(id: "s1", to: .ready)
        _ = coordinator.terminals.makeSession(id: "s1", cwd: dir.path, title: "claude", agentKind: .claude)

        XCTAssertThrowsError(try coordinator.switchModel(in: dir.path, agent: .claude, to: "luna")) { error in
            guard case LinkCError.process(let msg) = error else {
                return XCTFail("Expected LinkCError.process, got: \(error)")
            }
            XCTAssertTrue(msg.contains("luna"), msg)
            XCTAssertTrue(msg.contains("haiku"), msg)
            XCTAssertTrue(msg.contains("sonnet"), msg)
            XCTAssertTrue(msg.contains("opus"), msg)
        }
    }
}
