import XCTest
@testable import LinkCKit

final class TaskRecordEffortTests: XCTestCase {
    /// Rows written before efforts existed must still decode; a required field would take the inbox with it.
    func testOldTaskRowsWithoutEffortStillDecode() throws {
        let json = """
        {
          "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "fromAgent": "claude",
          "toAgent": "codex",
          "prompt": "Build it",
          "files": [],
          "state": "queued",
          "hop": 0,
          "createdAt": 0,
          "leaseExpiresAt": 0,
          "unreportedTurnEndNotified": false
        }
        """
        let task = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
        XCTAssertNil(task.effort)
        XCTAssertEqual(task.prompt, "Build it")
    }

    func testEffortRoundTripsOnATask() throws {
        let task = TaskRecord(
            fromAgent: .claude, tier: .deep, effort: .high, toAgent: .codex,
            prompt: "Hard debug", files: [])
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded.effort, .high)
        XCTAssertEqual(decoded.tier, .deep)
    }

    func testCreateTaskPersistsEffort() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-task-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inbox = InboxStore(workspaceRoot: dir.path)
        let task = try inbox.createTask(
            from: .claude, to: .codex, tier: .light, effort: .low,
            prompt: "Rename a typo", files: [])
        XCTAssertEqual(task.effort, .low)
        XCTAssertEqual(try inbox.task(id: task.id)?.effort, .low)
    }
}
