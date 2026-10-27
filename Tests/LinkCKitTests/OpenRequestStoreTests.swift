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
