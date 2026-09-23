import XCTest
@testable import LinkCKit

/// A clock the test releases by hand: each `sleep` waits until `release()` is called.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    var waiting: Int { waiters.count }
}

@MainActor
final class BoardModelTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-board-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private var store: BoardMapStore { BoardMapStore(workspacePath: workspace.path) }

    private func model(_ gate: Gate = Gate()) -> BoardModel {
        BoardModel(store: store, settle: .milliseconds(600), sleep: { _ in await gate.wait() })
    }

    private func fresh() -> BoardModel {
        let board = model()
        board.load()
        board.startMap()
        return board
    }

    private func settle(_ gate: Gate, waiting count: Int) async {
        for _ in 0..<400 where await gate.waiting < count { await Task.yield() }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    // MARK: Loading and writing

    func testOpeningAProjectWithNoMapWritesNothing() {
        let board = model()
        board.load()
        board.reconcile(with: [DiscoveredThing(name: "db", image: "postgres", detail: "container db")])
        board.startMap()
        board.saveNow()
        XCTAssertEqual(board.state, .loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testAMapNobodyEditedIsNeverRewritten() throws {
        let bytes = Data(#"{"version": 2, "places": {"Not placed": {"api": {"kind": "service", "zz": 1}}}}"#.utf8)
        try bytes.write(to: store.fileURL)
        let board = model()
        board.load()
        board.reconcile(with: [])
        board.selection = [.component("api")]
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    func testAVersionOneFileIsWrittenAsVersionTwoOnlyOnItsFirstEdit() throws {
        let v1 = Data(#"{"version": 1, "components": [{"name": "api", "kind": "service"}]}"#.utf8)
        try v1.write(to: store.fileURL)
        let board = model()
        board.load()
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), v1, "opening never upgrades the file")
        board.setSystem("June")
        board.saveNow()
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 2)
    }

    func testAnUnreadableMapLocksTheBoard() throws {
        let bytes = Data("{ nope".utf8)
        try bytes.write(to: store.fileURL)
        let board = model()
        board.load()
        guard case .failed(let reason) = board.state else { return XCTFail("\(board.state)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(board.addComponent(kind: .cache, at: BoardPoint(x: 0, y: 0)))
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    func testEditsAreWrittenOncePerBurst() async throws {
        let gate = Gate()
        let board = model(gate)
        board.load()
        board.startMap()
        board.setSystem("June")
        _ = board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0))
        await settle(gate, waiting: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        await gate.release()   // the first edit's clock — stale, writes nothing
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "a stale timer must not write")

        await gate.release()   // the second edit's clock — writes both edits
        await settleUntil { FileManager.default.fileExists(atPath: self.store.fileURL.path) }
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.map.system, "June")
        XCTAssertEqual(loaded.map.components.count, 1)
    }

    /// A change made underneath the board — a git pull, a hand edit — is never overwritten.
    func testAChangeOnDiskRefusesTheWriteAndLocksUntilReload() throws {
        let board = fresh()
        board.setSystem("mine")
        board.saveNow()
        let theirs = Data(#"{"version": 2, "system": "theirs", "places": {"Not placed": {}}}"#.utf8)
        try theirs.write(to: store.fileURL)

        board.setSystem("mine again")
        board.saveNow()
        XCTAssertTrue(board.changedOnDisk)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), theirs)
        XCTAssertNil(board.addComponent(kind: .cache, at: BoardPoint(x: 0, y: 0)), "no edits while the disk disagrees")

        board.reload()
        XCTAssertFalse(board.changedOnDisk)
        XCTAssertEqual(board.map.system, "theirs")
    }

    func testAFailedWriteStaysEditableAndRetries() throws {
        let board = fresh()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)  // a folder where the file must go
        board.setSystem("June")
        board.saveNow()
        XCTAssertNotNil(board.writeFailure)
        XCTAssertEqual(board.state, .loaded)

        try FileManager.default.removeItem(at: store.fileURL)
        board.setSystem("June, again")
        board.saveNow()
        XCTAssertNil(board.writeFailure)
        XCTAssertEqual(try store.load()?.map.system, "June, again")
    }

    /// Reappearing — a tab switch back to the Board — must not wipe undo: `LinkCApp.swift`
    /// promises it survives switching tabs. Reloading bytes that did not change is a no-op.
    func testReappearingWithNoChangeOnDiskKeepsUndoAndSelection() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        board.setSystem("June")
        board.saveNow()
        XCTAssertTrue(board.canUndo)
        board.selection = [.component(api)]

        board.load()
        XCTAssertTrue(board.canUndo, "the file on disk did not change, so undo must survive reappearing")
        XCTAssertEqual(board.map.system, "June")
        XCTAssertEqual(board.selection, [.component(api)], "selection is kept too")
    }

    /// A real change on disk — a hand edit, a git pull — still reloads and clears undo, exactly
    /// as it always has.
    func testAChangeOnDiskStillReloadsAndClearsUndo() throws {
        let board = fresh()
        board.setSystem("June")
        board.saveNow()
        XCTAssertTrue(board.canUndo)

        let theirs = Data(#"{"version": 2, "system": "theirs", "places": {"Not placed": {}}}"#.utf8)
        try theirs.write(to: store.fileURL)

        board.load()
        XCTAssertFalse(board.canUndo, "a real change on disk still clears undo")
        XCTAssertEqual(board.map.system, "theirs")
    }

    /// R1: a corrupted file locks the board, same as `testAnUnreadableMapLocksTheBoard`. Once the
    /// exact old bytes are back, "Try again" (`reload()`) must unlock it — even though those bytes
    /// equal what `diskBytes` already held, the shortcut that keeps state untouched must not fire
    /// while the board is `.failed`.
    func testTryAgainRecoversOnceTheOldBytesAreRestoredAfterCorruption() throws {
        let board = fresh()
        board.setSystem("June")
        board.saveNow()
        let goodBytes = try Data(contentsOf: store.fileURL)

        try Data("{ not json".utf8).write(to: store.fileURL)
        board.load()
        guard case .failed = board.state else { return XCTFail("expected .failed, got \(board.state)") }

        try goodBytes.write(to: store.fileURL)
        board.reload()
        XCTAssertEqual(board.state, .loaded, "Try again must unlock once the old bytes are back")
        XCTAssertEqual(board.map.system, "June")
    }

    /// R2: a file malformed on first open — `diskBytes` is still nil, nothing was ever read. Once
    /// it is deleted, "Try again" must settle on `.empty`, not stay stuck `.failed`.
    func testTryAgainRecoversWhenAMalformedFileIsDeleted() throws {
        try Data("{ not json".utf8).write(to: store.fileURL)
        let board = model()
        board.load()
        guard case .failed = board.state else { return XCTFail("expected .failed, got \(board.state)") }

        try FileManager.default.removeItem(at: store.fileURL)
        board.reload()
        XCTAssertEqual(board.state, .empty, "Try again must recover once the malformed file is gone")
    }

    /// R3: locked by `changedOnDisk`, then the disk goes back to exactly linkC's own last bytes —
    /// a stash, then a pop. Reload must still unlock, and must still drop the unwritten edit that
    /// caused the refusal, even though the bytes it reads back match `diskBytes` exactly.
    func testReloadRecoversWhenTheDiskGoesBackToLinkCsOwnBytes() throws {
        let board = fresh()
        board.setSystem("mine")
        board.saveNow()
        let ownBytes = try Data(contentsOf: store.fileURL)

        let theirs = Data(#"{"version": 2, "system": "theirs", "places": {"Not placed": {}}}"#.utf8)
        try theirs.write(to: store.fileURL)

        board.setSystem("mine again")
        board.saveNow()
        XCTAssertTrue(board.changedOnDisk)
        XCTAssertNil(board.addComponent(kind: .cache, at: BoardPoint(x: 0, y: 0)), "no edits while the disk disagrees")

        try ownBytes.write(to: store.fileURL)   // the stash pop: back to linkC's own last bytes
        board.reload()
        XCTAssertFalse(board.changedOnDisk, "reload must unlock even when the file is back to linkC's own bytes")
        XCTAssertEqual(board.map.system, "mine", "the unwritten edit reload should drop must be gone")
    }

    // MARK: Undo

    func testUndoAndRedoWalkTheEdits() {
        let board = fresh()
        board.setSystem("one")
        board.setSystem("two")
        XCTAssertTrue(board.canUndo)
        board.undo()
        XCTAssertEqual(board.map.system, "one")
        board.redo()
        XCTAssertEqual(board.map.system, "two")
        board.undo()
        board.setSystem("three")
        XCTAssertFalse(board.canRedo, "a new edit clears the redo stack")
    }

    /// A refusal left over from a rejected edit must not linger once undo or redo has moved the
    /// board somewhere else — it describes an edit that no longer applies.
    func testUndoAndRedoClearAStaleRefusal() throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 400, y: 0)))

        var clash = try XCTUnwrap(board.map.components.first { $0.name == b })
        clash.name = a
        XCTAssertFalse(board.updateComponent(b, to: clash))
        XCTAssertNotNil(board.refusal, "the rename was refused")

        board.undo()
        XCTAssertNil(board.refusal, "undo clears a stale refusal")
        XCTAssertNil(board.map.components.first { $0.name == b }, "the add of b really was undone")

        XCTAssertFalse(board.addArrow(from: a, to: a))
        XCTAssertNotNil(board.refusal, "a fresh refusal, right before redo")

        board.redo()
        XCTAssertNil(board.refusal, "redo clears a stale refusal")
        XCTAssertNotNil(board.map.components.first { $0.name == b }, "the redo really brought b back")
    }

    func testUndoKeepsAtMostAHundredSteps() {
        let board = fresh()
        for index in 0...150 { board.setSystem("\(index)") }
        var steps = 0
        while board.canUndo { board.undo(); steps += 1 }
        XCTAssertEqual(steps, BoardModel.undoLimit)
    }

    // MARK: Content

    func testANewComponentGetsAUniqueNameIsPlannedAndIsSelected() throws {
        let board = fresh()
        let first = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0)))
        let second = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0)))
        XCTAssertEqual(first, "new-database")
        XCTAssertEqual(second, "new-database-2")
        XCTAssertTrue(board.map.components.allSatisfy(\.planned))
        XCTAssertEqual(board.selection, [.component("new-database-2")])
        let rects = board.map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
        XCTAssertFalse(rects[0].intersects(rects[1]), "the second slid off the first")
    }

    func testAComponentAddedInsideAFrameLivesThere() throws {
        let board = fresh()
        let frame = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let name = try XCTUnwrap(board.addComponent(kind: .cache, at: BoardPoint(x: 40, y: 40)))
        XCTAssertEqual(board.map.components.first { $0.name == name }?.place, frame)
    }

    func testAFrameAdoptsWhatItIsDrawnAroundAndRefusesToCutThroughThings() throws {
        let board = fresh()
        let name = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 40, y: 40)))
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        XCTAssertEqual(board.map.components.first { $0.name == name }?.place, label)

        XCTAssertNil(board.addFrame(BoardRect(x: 100, y: 0, w: 400, h: 200)), "it would cross the first frame")
        XCTAssertNotNil(board.refusal)
    }

    func testRenamingAComponentCarriesItsArrowsAndSelection() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 400, y: 0)))
        XCTAssertTrue(board.addArrow(from: api, to: db))
        var renamed = try XCTUnwrap(board.map.components.first { $0.name == db })
        renamed.name = "postgres"
        renamed.does = "entries"
        board.selection = [.component(db)]
        XCTAssertTrue(board.updateComponent(db, to: renamed))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses, ["postgres": ""])
        XCTAssertEqual(board.map.components.first { $0.name == "postgres" }?.does, "entries")
        XCTAssertEqual(board.selection, [.component("postgres")])
    }

    func testANameInUseIsRefusedAndNothingChanges() throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 400, y: 0)))
        var clash = try XCTUnwrap(board.map.components.first { $0.name == b })
        clash.name = a.uppercased()
        XCTAssertFalse(board.updateComponent(b, to: clash))
        XCTAssertNotNil(board.refusal)
        XCTAssertEqual(Set(board.map.components.map(\.name)), [a, b])
        _ = board.addNote(at: BoardPoint(x: 0, y: 400))
        XCTAssertNil(board.refusal, "the next edit that lands clears it")
    }

    func testArrowRules() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 400, y: 0)))
        XCTAssertFalse(board.addArrow(from: api, to: api), "no arrow to itself")
        XCTAssertTrue(board.addArrow(from: api, to: db))
        XCTAssertFalse(board.addArrow(from: api, to: db), "no second arrow the same way")
        XCTAssertNotNil(board.routes[BoardModel.ArrowKey(from: api, to: db)])
        board.setArrowLabel(BoardModel.ArrowKey(from: api, to: db), to: "reads entries")
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses[db], "reads entries")
    }

    /// A second arrow to the same component spelled in another case is still the same arrow —
    /// not a second entry under a different key.
    func testAddArrowDuplicateCheckIsCaseInsensitiveAndKeepsTheRealSpelling() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 400, y: 0)))
        XCTAssertTrue(board.addArrow(from: api, to: db))
        XCTAssertFalse(board.addArrow(from: api, to: db.uppercased()), "same arrow, different case, is still a duplicate")
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses, [db: ""], "one entry, under the real spelling")
    }

    func testDeletingAComponentTakesItsArrowsAndDeletingAFrameKeepsItsContents() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 600, y: 0)))
        XCTAssertTrue(board.addArrow(from: api, to: db))

        board.delete([.component(db)])
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses, [:])
        XCTAssertTrue(board.routes.isEmpty)

        board.delete([.frame(label)])
        XCTAssertTrue(board.map.frames.isEmpty)
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, BoardMap.notPlaced)
    }

    func testANoteAndAText() throws {
        let board = fresh()
        let note = try XCTUnwrap(board.addNote(at: BoardPoint(x: 0, y: 0)))
        board.setNoteText(note, to: "Redis is for sessions")
        XCTAssertEqual(board.map.notes.first?.text, "Redis is for sessions")
        let text = try XCTUnwrap(board.addText(at: BoardPoint(x: 0, y: 300), style: .title, text: "June", width: 64))
        board.setText(text, to: "", width: 0)
        XCTAssertTrue(board.map.texts.isEmpty, "a text emptied of words goes away")
    }

    /// Widening a text through `setText` must slide clear of things beside it, exactly as a move
    /// would — every new text starts as "Text" and is renamed right after, so a wide name landing
    /// on the box beside it is the everyday case, not an edge case.
    func testWideningATextBesideABoxKeepsItClearOfTheBox() throws {
        let board = fresh()
        let box = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 100, y: 0)))
        let textId = try XCTUnwrap(board.addText(at: BoardPoint(x: 0, y: 0), style: .label, text: "hi", width: 30))
        board.setText(textId, to: "hi there, a much longer line", width: 200)
        let boxRect = try XCTUnwrap(board.rect(of: .component(box)))
        let textRect = try XCTUnwrap(board.rect(of: .text(textId)))
        XCTAssertFalse(boxRect.intersects(textRect))
    }

    /// Widening a text that started near a frame's right edge follows the same drop rule a moved
    /// element does: since its centre stays inside the frame, it settles wholly inside it rather
    /// than sticking out past the edge.
    func testWideningATextInsideAFrameStaysWhollyInside() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let textId = try XCTUnwrap(board.addText(at: BoardPoint(x: 300, y: 8), style: .label, text: "hi", width: 30))
        board.setText(textId, to: "hi there, a longer line", width: 100)
        let frame = try XCTUnwrap(board.map.frames.first { $0.label == label }?.rect)
        let textRect = try XCTUnwrap(board.rect(of: .text(textId)))
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(textRect))
    }

    func testRenamingAFrameMovesItsComponentsToTheNewPlace() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        XCTAssertTrue(board.renameFrame(label, to: "Local docker"))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, "Local docker")
        XCTAssertFalse(board.renameFrame("Local docker", to: "not PLACED"), "the reserved name is refused")
    }

    func testRenamingAFrameCarriesItsSelection() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        board.selection = [.frame(label)]
        XCTAssertTrue(board.renameFrame(label, to: "Local docker"))
        XCTAssertEqual(board.selection, [.frame("Local docker")])
    }

    // MARK: What's running

    func testReconcilingNeverWritesAndReportsWhatIsNotOnTheMap() {
        let board = fresh()
        board.reconcile(with: [DiscoveredThing(name: "minio", image: "minio/minio", detail: "container minio")])
        XCTAssertEqual(board.suggestions.map(\.name), ["minio"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testAddingWhatIsRunningPutsItAllInALocalDockerFrame() throws {
        let board = model()
        board.load()
        board.reconcile(with: [
            DiscoveredThing(name: "api", image: "june-api", detail: "container api"),
            DiscoveredThing(name: "db", image: "postgres:16", detail: "container db"),
        ])
        board.addAllRunning()
        XCTAssertEqual(board.map.frames.map(\.label), ["Local docker"])
        XCTAssertEqual(Set(board.map.components.map(\.name)), ["api", "db"])
        XCTAssertTrue(board.map.components.allSatisfy { $0.place == "Local docker" && !$0.planned })
        XCTAssertEqual(board.map.components.first { $0.name == "db" }?.kind, .database)
        XCTAssertEqual(board.statuses["db"], .present)
        XCTAssertTrue(board.suggestions.isEmpty)
        board.undo()
        XCTAssertTrue(board.map.components.isEmpty, "it was one step")
    }

    /// Every suggestion already named on the map adds nothing — so it must not be an edit.
    func testAddingASuggestionAlreadyOnTheMapIsNotAnEdit() throws {
        let bytes = Data(#"{"version": 2, "places": {"Not placed": {"redis": {"kind": "cache"}}}}"#.utf8)
        try bytes.write(to: store.fileURL)
        let board = model()
        board.load()
        XCTAssertFalse(board.canUndo)

        board.addSuggestion(MapSuggestion(name: "redis", kind: .cache, detail: "container redis"))
        XCTAssertFalse(board.canUndo, "nothing was added, so nothing to undo")

        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes, "a no-op addition must not write")
    }

    /// The same, in one batch: every discovered thing already named on the map.
    func testAddingAllRunningWhenEverythingIsAlreadyOnTheMapIsNotAnEdit() throws {
        let bytes = Data(#"{"version": 2, "places": {"Not placed": {"redis": {"kind": "cache"}}}}"#.utf8)
        try bytes.write(to: store.fileURL)
        let board = model()
        board.load()
        board.reconcile(with: [DiscoveredThing(name: "redis", image: "redis", detail: "container redis")])
        XCTAssertTrue(board.suggestions.isEmpty, "already on the map, so not a suggestion at all")

        board.addAllRunning()
        XCTAssertFalse(board.canUndo)
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    /// Two suggestions with the same name, differently cased, in one batch: the batch itself
    /// must de-duplicate, the same way it already does against the map.
    func testAddingAllRunningDeduplicatesTheBatchCaseInsensitively() throws {
        let board = fresh()
        board.reconcile(with: [
            DiscoveredThing(name: "redis", image: "redis", detail: "container redis"),
            DiscoveredThing(name: "REDIS", image: "redis", detail: "container REDIS again"),
        ])
        XCTAssertEqual(board.suggestions.count, 2, "the reconciler itself does not dedupe casing")

        board.addAllRunning()
        XCTAssertEqual(board.map.components.count, 1, "one batch must not add the same name twice")
    }

    /// Adding suggestions one at a time until the "Local docker" frame has no room left grows it
    /// downward — every component still ends up inside the frame, none overlapping.
    func testAddingSuggestionsOneAtATimeGrowsTheFrameToFitThemAll() throws {
        let board = fresh()
        for index in 0..<4 {
            board.addSuggestion(MapSuggestion(name: "svc\(index)", kind: .service, detail: "container svc\(index)"))
        }
        XCTAssertNil(board.refusal)
        let frame = try XCTUnwrap(board.map.frames.first { $0.label == BoardModel.localDocker })
        let interior = BoardGeometry.interior(of: try XCTUnwrap(frame.rect))
        let rects = board.map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
        XCTAssertEqual(rects.count, 4)
        for rect in rects {
            XCTAssertTrue(interior.contains(rect), "\(rect) is not inside the frame's interior \(interior)")
        }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                XCTAssertFalse(rects[i].intersects(rects[j]), "\(rects[i]) overlaps \(rects[j])")
            }
        }
        XCTAssertTrue(board.map.components.allSatisfy { $0.place == BoardModel.localDocker })
    }

    /// A "Local docker" frame hemmed in below by another frame cannot grow: the component that
    /// does not fit lands outside every frame, and the board says why.
    func testASuggestionThatCannotFitIsPlacedOutsideEveryFrameAndRefused() throws {
        let board = fresh()
        let dockerLabel = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 200, h: 96)))
        XCTAssertTrue(board.renameFrame(dockerLabel, to: BoardModel.localDocker))
        // Directly under it, touching its bottom edge, so growing downward runs straight into it.
        _ = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 96, w: 200, h: 96)))

        board.addSuggestion(MapSuggestion(name: "first", kind: .service, detail: "container first"))
        XCTAssertEqual(board.map.components.first { $0.name == "first" }?.place, BoardModel.localDocker, "the first one still fits")
        XCTAssertNil(board.refusal)

        board.addSuggestion(MapSuggestion(name: "second", kind: .service, detail: "container second"))
        let second = try XCTUnwrap(board.map.components.first { $0.name == "second" })
        XCTAssertEqual(second.place, BoardMap.notPlaced)
        let secondRect = try XCTUnwrap(second.at.map(BoardGeometry.rect(ofComponentAt:)))
        let frameRects = board.map.frames.compactMap(\.rect)
        XCTAssertTrue(frameRects.allSatisfy { !$0.intersects(secondRect) }, "outside every frame")
        let allRects = board.map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
        XCTAssertTrue(allRects.filter { $0 != secondRect }.allSatisfy { !$0.intersects(secondRect) }, "overlaps nothing")
        XCTAssertEqual(board.refusal, "No room left in Local docker — the new component is outside it; drag it in or make room.")
    }

    /// When "Local docker" has no room and cannot grow, the container is filed under whichever
    /// frame its landing spot's centre actually falls in — not blindly "Not placed" just because
    /// it overflowed Local docker.
    func testASuggestionThatOverflowsLocalDockerIsFiledUnderTheFrameItLandsIn() throws {
        let board = fresh()
        let dockerLabel = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 200, h: 96)))
        XCTAssertTrue(board.renameFrame(dockerLabel, to: BoardModel.localDocker))
        // Blocks Local docker from growing downward.
        _ = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 96, w: 200, h: 96)))
        // Sits exactly where the overflow's fallback spot lands — to the right of Local docker.
        let other = try XCTUnwrap(board.addFrame(BoardRect(x: 248, y: 0, w: 300, h: 150)))

        board.addSuggestion(MapSuggestion(name: "first", kind: .service, detail: "container first"))
        XCTAssertEqual(board.map.components.first { $0.name == "first" }?.place, BoardModel.localDocker, "the first one still fits")

        board.addSuggestion(MapSuggestion(name: "second", kind: .service, detail: "container second"))
        let second = try XCTUnwrap(board.map.components.first { $0.name == "second" })
        let secondRect = try XCTUnwrap(second.at.map(BoardGeometry.rect(ofComponentAt:)))
        let otherRect = try XCTUnwrap(board.map.frames.first { $0.label == other }?.rect)
        XCTAssertTrue(otherRect.contains(secondRect.center), "the landing spot really is inside the other frame")
        XCTAssertEqual(second.place, other, "its place must match where it actually landed")
    }

    /// A note (or text) already inside "Local docker" is not a component, so it has no `place` —
    /// but it must still be avoided, both when searching for a spot and when growing the frame.
    func testAddingARunningContainerAvoidsANoteAtTheFramesFirstFreeSpot() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        XCTAssertTrue(board.renameFrame(label, to: BoardModel.localDocker))
        let frame = try XCTUnwrap(board.map.frames.first { $0.label == BoardModel.localDocker }?.rect)
        let seedOrigin = BoardPoint(x: frame.x + BoardGeometry.frameInset, y: frame.y + BoardGeometry.frameInset)
        let note = try XCTUnwrap(board.addNote(at: seedOrigin))
        XCTAssertEqual(board.map.notes.first { $0.id == note }?.at, seedOrigin, "the note must land exactly at the frame's first free spot")

        board.addSuggestion(MapSuggestion(name: "svc", kind: .service, detail: "container svc"))
        let svc = try XCTUnwrap(board.map.components.first { $0.name == "svc" })
        XCTAssertEqual(svc.place, BoardModel.localDocker)
        let svcRect = try XCTUnwrap(svc.at.map(BoardGeometry.rect(ofComponentAt:)))
        let noteRect = try XCTUnwrap(board.map.notes.first { $0.id == note }?.at.map(BoardGeometry.rect(ofNoteAt:)))
        XCTAssertFalse(svcRect.intersects(noteRect), "the new component must not land on the note already in the frame")
    }
}
