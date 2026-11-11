import XCTest
import os
@testable import LinkCKit

@MainActor
final class ModelListRefresherTests: XCTestCase {
    private var dir: URL!
    private var cache: ModelListCache!

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
