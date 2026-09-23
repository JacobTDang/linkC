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

    /// Gives a resumed task room to run without waiting on any condition — for proving a
    /// *negative*, where there is nothing to poll for.
    private func yieldMany(_ times: Int = 100) async {
        for _ in 0..<times { await Task.yield() }
    }

    func testAProjectWithNoMapLoadsEmpty() {
        let model = makeModel(gate: Gate())
        model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.map.components.isEmpty)
    }

    /// Opening a project's dashboard and closing it must never create a file nobody asked for —
    /// `saveNow()` only fires the pending timer early; it must not invent a write of its own.
    func testSaveNowWritesNothingWhenABoardWasOnlyLookedAt() {
        let model = makeModel(gate: Gate())
        model.load()
        model.reconcile(with: [])
        model.saveNow()

        let store = SystemMapStore(workspacePath: workspace.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path),
            "a board nobody edited must leave an absent file absent")
    }

    /// The same, for a project that already has a hand-edited map: looking at it must not
    /// re-encode it — that would reorder keys, trim values, and materialise a default `kind`
    /// into a component that omitted it, producing a spurious diff in a committed file.
    func testSaveNowLeavesAHandEditedFileUntouchedWhenABoardWasOnlyLookedAt() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handEdited = Data(#"{"version": 1, "components": [{"name": "redis"}]}"#.utf8)
        try handEdited.write(to: store.fileURL)

        let model = makeModel(gate: Gate())
        model.load()
        model.reconcile(with: [])
        model.saveNow()

        XCTAssertEqual(
            try Data(contentsOf: store.fileURL), handEdited,
            "a board nobody edited must not materialise a default kind into a hand-edited file")
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

        // Two edits scheduled two timers. Release them one at a time and inspect the file
        // between releases: the first timer is stale by the time its clock runs out (a
        // generation-less implementation would write here too, since the map already holds its
        // final state in memory — that write is exactly what must not happen).
        await gate.release()
        await yieldMany()
        XCTAssertNil(try store.load(), "a stale timer must not write at all")

        // Only the second, live timer may write.
        await gate.release()
        await settleUntil { (try? store.load()) != nil }
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

    func testUpdatingAComponentToAnExistingNameIsRefusedWithoutLockingTheBoard() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.add(SystemComponent(name: "postgres", kind: .database))

        var clash = model.map.components[1]
        clash.name = "REDIS"
        model.update("postgres", to: clash)

        XCTAssertEqual(model.map.components.map(\.name), ["redis", "postgres"], "the clash is refused")
        XCTAssertEqual(model.state, .loaded, "a refused name is not a broken file")
        XCTAssertEqual(model.refusal?.lowercased().contains("redis"), true)
    }

    /// A refusal from one kind of edit must not survive an unrelated edit that succeeds —
    /// `remove` and `move` land just as much as `add` and `update` do.
    func testARefusalClearsOnASuccessfulMove() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.add(SystemComponent(name: "REDIS", kind: .database))
        XCTAssertNotNil(model.refusal, "the duplicate add must be refused first")

        model.move("redis", to: GridPoint(x: 3, y: 3))

        XCTAssertNil(model.refusal, "a successful drag must not leave a stale refusal on screen")
    }

    /// A drag with no upper bound could push a tile past the grid's columns and off the board
    /// for good, since nothing scrolls it back into view.
    func testAMoveNeverLandsPastTheGridsColumns() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "api", kind: .service))

        model.move("api", to: GridPoint(x: 999, y: 0))

        let landed = try? XCTUnwrap(model.positions["api"])
        XCTAssertEqual(landed?.x, WorkbenchLayout.columns - 1, "a tile can never be dragged past the last column")
    }

    /// `WorkbenchModel.move` used to accept any cell, and `WorkbenchLayout` would then bump
    /// whichever component lost the collision by name order — so the file recorded a position
    /// the board never drew, and dragging one tile could visibly move another. The model must
    /// decide the landing cell itself, so the file and the screen always agree.
    func testAMoveOntoAnOccupiedCellLandsOnAFreeOneInstead() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "alpha", kind: .service, at: GridPoint(x: 1, y: 0)))
        model.add(SystemComponent(name: "beta", kind: .service, at: GridPoint(x: 2, y: 0)))

        model.move("beta", to: GridPoint(x: 1, y: 0))

        XCTAssertEqual(model.positions["alpha"], GridPoint(x: 1, y: 0), "the tile nobody dragged must not move")
        XCTAssertNotEqual(model.positions["beta"], model.positions["alpha"], "a drop on an occupied cell must not overwrite the tile already there")
        XCTAssertEqual(
            model.map.components.first { $0.name == "beta" }?.at, model.positions["beta"],
            "the file must record exactly the cell the board draws")
    }

    func testARefusalClearsOnASuccessfulRemove() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.add(SystemComponent(name: "postgres", kind: .database))
        model.add(SystemComponent(name: "REDIS", kind: .database))
        XCTAssertNotNil(model.refusal, "the duplicate add must be refused first")

        model.remove("postgres")

        XCTAssertNil(model.refusal, "a successful removal must not leave a stale refusal on screen")
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

    /// A failed write is not a broken file: the map in memory is still good, so the board must
    /// stay open, not lock the way a failed read does.
    func testAFailedWriteStaysEditableAndSurfacesSeparatelyFromState() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        // No file exists yet, so `load()` reads cleanly — only the write, into a directory with
        // its write bit removed, is what must fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workspace.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.path) }

        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.saveNow()

        XCTAssertEqual(model.state, .loaded, "a failed write must not look like a broken file")
        XCTAssertNotNil(model.writeFailure, "the failure must be visible somewhere")

        // The board is still editable: the next edit lands in memory right away.
        model.add(SystemComponent(name: "postgres", kind: .database))
        XCTAssertEqual(model.map.components.map(\.name), ["redis", "postgres"])
    }

    func testAWriteThatSucceedsClearsAPriorFailure() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workspace.path)

        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.saveNow()
        XCTAssertNotNil(model.writeFailure, "the first write must fail while the directory is read-only")

        // Clear the obstruction and retry — the same edit, still only in memory, tries again.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.path)
        model.saveNow()

        XCTAssertNil(model.writeFailure, "a write that lands clears the failure")
        XCTAssertEqual(try store.load()?.components.map(\.name), ["redis"])
    }

    /// A reload that replaced `map` here would silently throw away an edit a failed write never
    /// got to persist — `load()` must refuse instead.
    func testLoadRefusesToReplaceAMapWithUnwrittenEdits() throws {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        // The scheduled write from `add` never fires: this test's gate is never released, so
        // the edit above is still only in memory.

        let store = SystemMapStore(workspacePath: workspace.path)
        try store.save(SystemMap(components: [SystemComponent(name: "mongo", kind: .database)]))

        model.load()

        XCTAssertEqual(
            model.map.components.map(\.name), ["redis"],
            "a reload must never discard edits that were never written")
    }

    func testASecondBurstOfEditsWritesAfterAFirstSuccessfulWrite() async throws {
        let gate = Gate()
        let model = makeModel(gate: gate)
        model.load()
        model.startMap()
        let store = SystemMapStore(workspacePath: workspace.path)

        model.add(SystemComponent(name: "redis", kind: .cache))
        await settle(gate, waiting: 1)
        await gate.release()
        await settleUntil { (try? store.load())??.components.map(\.name) == ["redis"] }

        model.add(SystemComponent(name: "postgres", kind: .database))
        await settle(gate, waiting: 1)
        await gate.release()
        await settleUntil { (try? store.load())??.components.map(\.name) == ["redis", "postgres"] }

        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved.components.map(\.name), ["redis", "postgres"])
    }
}
