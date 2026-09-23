import XCTest
@testable import LinkCKit

/// A clock the test releases by hand: each `sleep` waits until `release()` is called.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    var waiting: Int { waiters.count }
}

@MainActor
final class WorkbenchModelTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-workbench-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func makeModel(gate: Gate) -> WorkbenchModel {
        WorkbenchModel(
            store: SystemMapStore(workspacePath: workspace.path),
            settle: .milliseconds(600),
            sleep: { _ in await gate.wait() })
    }

    private func settle(_ gate: Gate, waiting count: Int) async {
        for _ in 0..<200 where await gate.waiting < count { await Task.yield() }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testAProjectWithNoMapLoadsEmpty() {
        let model = makeModel(gate: Gate())
        model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.map.components.isEmpty)
    }

    func testAnUnreadableMapFailsLoudAndRefusesToWrite() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{ nope".utf8)
        try bytes.write(to: store.fileURL)

        let model = makeModel(gate: Gate())
        model.load()

        guard case .failed(let reason) = model.state else {
            return XCTFail("expected a failed state, got \(model.state)")
        }
        XCTAssertFalse(reason.isEmpty)

        model.add(SystemComponent(name: "redis", kind: .cache))
        model.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes, "a map linkC could not read must never be overwritten")
    }

    func testAnEditIsWrittenOnceAfterTheSettle() async throws {
        let gate = Gate()
        let model = makeModel(gate: gate)
        model.load()
        model.startMap()

        model.add(SystemComponent(name: "postgres", kind: .database))
        model.move("postgres", to: GridPoint(x: 2, y: 1))
        await settle(gate, waiting: 2)

        let store = SystemMapStore(workspacePath: workspace.path)
        XCTAssertNil(try store.load()?.components.first?.at, "nothing is written before the settle")

        // Two edits scheduled two writes; the first is stale by the time its clock runs out and
        // must write nothing, so only the second one lands.
        await gate.release()
        await gate.release()
        await settleUntil { (try? store.load())??.components.first?.at != nil }
        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved.components.map(\.name), ["postgres"])
        XCTAssertEqual(saved.components[0].at, GridPoint(x: 2, y: 1))
    }

    func testEditsChangeTheMapInMemoryRightAway() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()

        model.add(SystemComponent(name: "redis", kind: .cache, intended: true))
        XCTAssertEqual(model.map.components.map(\.name), ["redis"])
        XCTAssertNotNil(model.positions["redis"], "a new tile has a place on the board at once")

        var edited = model.map.components[0]
        edited.reachedBy = "REDIS_URL"
        edited.intended = false
        model.update("redis", to: edited)
        XCTAssertEqual(model.map.components[0].reachedBy, "REDIS_URL")
        XCTAssertFalse(model.map.components[0].intended)

        model.remove("redis")
        XCTAssertTrue(model.map.components.isEmpty)
    }

    func testAddingAComponentUnderAnExistingNameIsRefusedWithoutLockingTheBoard() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.add(SystemComponent(name: "REDIS", kind: .database))

        XCTAssertEqual(model.map.components.count, 1, "names identify components, whatever their case")
        XCTAssertEqual(model.state, .loaded, "a refused name is not a broken file")
        XCTAssertEqual(model.refusal?.lowercased().contains("redis"), true)

        model.add(SystemComponent(name: "postgres", kind: .database))
        XCTAssertEqual(model.map.components.count, 2, "the next edit still works")
        XCTAssertNil(model.refusal, "the refusal clears once something lands")
    }

    func testReconcileFillsStatusesAndSuggestions() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "postgres", kind: .database, runs: "docker compose (db)"))

        model.reconcile(with: [DiscoveredThing(name: "minio", image: "minio/minio", detail: "container minio")])

        XCTAssertEqual(model.statuses["postgres"], .missing)
        XCTAssertEqual(model.suggestions.map(\.name), ["minio"])
    }

    func testAFailedSaveIsSurfaced() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        // A file where the .linkc directory must go: creating the directory cannot succeed.
        try Data().write(to: store.fileURL.deletingLastPathComponent())

        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.saveNow()

        guard case .failed = model.state else {
            return XCTFail("a save that failed must not look like a save that worked")
        }
    }
}
