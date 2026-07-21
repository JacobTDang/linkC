import XCTest
@testable import LinkCKit

/// Persistence contract for the workspace manifest: it must round-trip through disk, tolerate a
/// missing or corrupt file (treat as empty), and mutate/persist entries by linkC id.
final class WorkspaceManifestTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-manifest-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func entry(
        _ linkcId: String,
        claude: String? = nil,
        cwd: String = "/tmp/proj",
        title: String = "proj",
        endedAt: Date? = nil
    ) -> RestorableSession {
        RestorableSession(linkcId: linkcId, claudeSessionId: claude, cwd: cwd, title: title, endedAt: endedAt)
    }

    func testRoundTripSaveLoad() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ended = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = WorkspaceManifest(directory: dir)
        manifest.upsert(entry("L1", claude: "c1", cwd: "/a", title: "a"))
        manifest.upsert(entry("L2", claude: nil, cwd: "/b", title: "b", endedAt: ended))

        // A fresh manifest over the same directory must observe exactly what was saved.
        let reloaded = WorkspaceManifest(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries.first { $0.linkcId == "L1" }, entry("L1", claude: "c1", cwd: "/a", title: "a"))
        let l2 = reloaded.entries.first { $0.linkcId == "L2" }
        XCTAssertEqual(l2?.cwd, "/b")
        XCTAssertNil(l2?.claudeSessionId)
        XCTAssertEqual(l2?.endedAt?.timeIntervalSince1970 ?? 0, ended.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingFileLoadsEmpty() {
        let dir = tempDir() // never created on disk
        let manifest = WorkspaceManifest(directory: dir)
        XCTAssertTrue(manifest.entries.isEmpty, "a missing manifest file must load as empty, not crash")
    }

    func testCorruptFileLoadsEmpty() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: dir.appendingPathComponent("workspace.json"))

        let manifest = WorkspaceManifest(directory: dir)
        XCTAssertTrue(manifest.entries.isEmpty, "a corrupt manifest file must load as empty, not crash")
    }

    func testUpsertReplacesByLinkcId() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = WorkspaceManifest(directory: dir)

        manifest.upsert(entry("L1", cwd: "/old", title: "old"))
        manifest.upsert(entry("L1", cwd: "/new", title: "new"))

        XCTAssertEqual(manifest.entries.count, 1, "upsert must replace, not duplicate, the same linkC id")
        XCTAssertEqual(manifest.entries.first?.cwd, "/new")
        XCTAssertEqual(manifest.entries.first?.title, "new")
    }

    func testBindClaudeIdUpdatesEntry() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = WorkspaceManifest(directory: dir)

        manifest.upsert(entry("L1"))
        XCTAssertNil(manifest.entries.first?.claudeSessionId)

        manifest.bindClaudeId(linkcId: "L1", claudeSessionId: "cabc")
        XCTAssertEqual(manifest.entries.first?.claudeSessionId, "cabc")

        // Persisted, and a no-op for an unknown id.
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.first?.claudeSessionId, "cabc")
        manifest.bindClaudeId(linkcId: "nope", claudeSessionId: "x")
        XCTAssertEqual(manifest.entries.count, 1)
    }

    func testMarkEndedSetsEndedAt() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = WorkspaceManifest(directory: dir)

        manifest.upsert(entry("L1"))
        XCTAssertNil(manifest.entries.first?.endedAt)

        let when = Date(timeIntervalSince1970: 1_700_000_500)
        manifest.markEnded(linkcId: "L1", at: when)
        XCTAssertEqual(manifest.entries.first?.endedAt?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)
        // Persisted.
        XCTAssertNotNil(WorkspaceManifest(directory: dir).entries.first?.endedAt)
        // A no-op for an unknown id (keeps the entry untouched).
        manifest.markEnded(linkcId: "nope", at: when)
        XCTAssertEqual(manifest.entries.count, 1)
    }

    func testRemoveDeletesEntry() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = WorkspaceManifest(directory: dir)

        manifest.upsert(entry("L1"))
        manifest.upsert(entry("L2"))
        manifest.remove(linkcId: "L1")

        XCTAssertEqual(manifest.entries.map(\.linkcId), ["L2"])
        // Persisted.
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.map(\.linkcId), ["L2"])
    }
}

extension WorkspaceManifestTests {
    /// M2: markEnded is idempotent — the first timestamp wins; a second call neither bumps the
    /// date nor rewrites the file.
    func testMarkEndedKeepsFirstTimestamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-manifest-\(UUID().uuidString)")
        let manifest = WorkspaceManifest(directory: dir)
        manifest.upsert(RestorableSession(linkcId: "X", cwd: "/tmp", title: "x"))
        let first = Date(timeIntervalSince1970: 1_000)
        manifest.markEnded(linkcId: "X", at: first)
        manifest.markEnded(linkcId: "X", at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(manifest.entries.first?.endedAt, first, "the first endedAt must win")
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.first?.endedAt, first, "and must be what was persisted")
    }
}
