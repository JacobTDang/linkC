import XCTest
@testable import LinkCKit

@MainActor
final class BoardFileWatcherTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!
    private var file: URL { folder.appendingPathComponent("system-map.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func expectChange(_ description: String, after change: () throws -> Void) throws {
        let fired = expectation(description: description)
        fired.assertForOverFulfill = false
        let watcher = try BoardFileWatcher(fileURL: file) { fired.fulfill() }
        defer { watcher.stop() }
        try change()
        wait(for: [fired], timeout: 2)
    }

    func testCreatingTheFileFires() throws {
        try expectChange("created") { try Data("{}".utf8).write(to: file) }
    }

    func testAnAtomicSaveFires() throws {
        try Data("{}".utf8).write(to: file)
        try expectChange("atomic") { try Data("{ }".utf8).write(to: file, options: .atomic) }
    }

    func testAnInPlaceWriteFires() throws {
        try Data("{}".utf8).write(to: file)
        try expectChange("in place") {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        }
    }

    /// Every terminal linkC starts later is forked from it: a descriptor the watcher left
    /// inheritable would stay open in each of those terminals for as long as they run.
    func testTheWatchersDescriptorsDoNotSurviveAnExec() throws {
        try Data("{}".utf8).write(to: file)
        let watcher = try BoardFileWatcher(fileURL: file) {}
        defer { watcher.stop() }

        let held = OpenDescriptors.on(file) + OpenDescriptors.on(folder)

        XCTAssertEqual(held.count, 2, "one descriptor on the file and one on its folder: \(held)")
        XCTAssertTrue(held.allSatisfy(\.closesOnExec), "\(held)")
    }

    func testTheDescriptorOpenedAfterAnAtomicSaveDoesNotSurviveAnExecEither() throws {
        try Data("{}".utf8).write(to: file)
        let saved = expectation(description: "saved")
        saved.assertForOverFulfill = false
        let watcher = try BoardFileWatcher(fileURL: file) { saved.fulfill() }
        defer { watcher.stop() }

        try Data("{ }".utf8).write(to: file, options: .atomic)
        wait(for: [saved], timeout: 2)

        let held = OpenDescriptors.on(file)
        XCTAssertFalse(held.isEmpty, "the watcher opens the replacement file")
        XCTAssertTrue(held.allSatisfy(\.closesOnExec), "\(held)")
    }

    func testAMissingFolderThrows() {
        XCTAssertThrowsError(try BoardFileWatcher(fileURL: folder.appendingPathComponent("nope/system-map.json")) {})
    }

    /// `stop()` must be safe to call more than once — `BoardPane` calls it on disappear, and a
    /// caller that replaces a watcher without keeping a stale reference around must never hang or
    /// crash doing so either way: explicitly, or by just letting the old one go.
    func testStopIsIdempotentAndDeinitWithoutAnExplicitStopIsSafe() throws {
        let watcher = try BoardFileWatcher(fileURL: file) {}
        watcher.stop()
        watcher.stop()   // must not hang or crash

        var another: BoardFileWatcher? = try BoardFileWatcher(fileURL: file) {}
        another = nil   // deinit, with no explicit stop() first — must not hang or crash
        _ = another
    }
}
