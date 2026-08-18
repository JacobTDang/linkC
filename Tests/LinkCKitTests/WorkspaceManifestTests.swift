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

        // Recent, whole-second date — an old fixture would age out of the reload below.
        let ended = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        let manifest = WorkspaceManifest(directory: dir)
        manifest.upsert(entry("L1", claude: "c1", cwd: "/a", title: "a"))
        manifest.upsert(entry("L2", claude: nil, cwd: "/b", title: "b", endedAt: ended))

        // A fresh manifest over the same directory must observe what was saved — except that
        // an entry still live at save time belongs to a run that is now dead, so the reload
        // stamps its endedAt (recovery is the moment we know it ended).
        let reloaded = WorkspaceManifest(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 2)
        let l1 = reloaded.entries.first { $0.linkcId == "L1" }
        XCTAssertEqual(l1?.claudeSessionId, "c1")
        XCTAssertEqual(l1?.cwd, "/a")
        XCTAssertNotNil(l1?.endedAt, "orphaned live entries are stamped at load")
        let l2 = reloaded.entries.first { $0.linkcId == "L2" }
        XCTAssertEqual(l2?.cwd, "/b")
        XCTAssertNil(l2?.claudeSessionId)
        XCTAssertEqual(l2?.endedAt?.timeIntervalSince1970 ?? 0, ended.timeIntervalSince1970, accuracy: 1)
    }

    /// Retention at load: orphans from a dead run get stamped (their age-out clock starts),
    /// week-old history drops, and each folder keeps only its newest entry — the Resume…
    /// launcher still reaches anything older.
    func testLoadStampsOrphansAgesOutAndDedupesPerFolder() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let seed = WorkspaceManifest(directory: dir)
        seed.upsert(entry("aged", cwd: "/a", endedAt: now.addingTimeInterval(-8 * 24 * 3600)))
        seed.upsert(entry("dupOld", cwd: "/b", endedAt: now.addingTimeInterval(-7200)))
        seed.upsert(entry("dupNew", cwd: "/b", endedAt: now.addingTimeInterval(-60)))
        seed.upsert(entry("orphan", cwd: "/c"))

        let reloaded = WorkspaceManifest(directory: dir, now: now)
        XCTAssertEqual(Set(reloaded.entries.map(\.linkcId)), ["dupNew", "orphan"])
        XCTAssertEqual(
            reloaded.entries.first { $0.linkcId == "orphan" }?.endedAt, now,
            "a dead run's live entry is stamped at load"
        )

        // The pruned list is what got persisted — a third open sees the same set.
        let third = WorkspaceManifest(directory: dir, now: now)
        XCTAssertEqual(Set(third.entries.map(\.linkcId)), ["dupNew", "orphan"])
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

        // Recent, whole-second date: old fixtures would age out of the reload below, and
        // ISO8601 persistence rounds to whole seconds.
        let when = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
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
    /// endedLabel is the home view's ended-time copy: nil while live, "just now" inside a
    /// minute (so near-now dates never render formatter artifacts like "in 0s"), relative after.
    func testEndedLabelNilWhileLive() {
        XCTAssertNil(entry("L1").endedLabel(now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testEndedLabelJustNowUnderAMinute() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Fresh, 30s old, and slight future clock skew all read as "just now" — never "in 0s".
        XCTAssertEqual(entry("L1", endedAt: now).endedLabel(now: now), "ended just now")
        XCTAssertEqual(entry("L1", endedAt: now.addingTimeInterval(-30)).endedLabel(now: now), "ended just now")
        XCTAssertEqual(entry("L1", endedAt: now.addingTimeInterval(5)).endedLabel(now: now), "ended just now")
    }

    func testEndedLabelRelativeBeyondAMinute() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let label = entry("L1", endedAt: now.addingTimeInterval(-5 * 60)).endedLabel(now: now)
        let unwrapped = try XCTUnwrap(label)
        XCTAssertTrue(unwrapped.hasPrefix("ended "), "got: \(unwrapped)")
        XCTAssertNotEqual(unwrapped, "ended just now")
        XCTAssertTrue(unwrapped.contains("5"), "expected the 5-minute figure in: \(unwrapped)")
    }

    /// M2: markEnded is idempotent — the first timestamp wins; a second call neither bumps the
    /// date nor rewrites the file.
    func testMarkEndedKeepsFirstTimestamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-manifest-\(UUID().uuidString)")
        let manifest = WorkspaceManifest(directory: dir)
        manifest.upsert(RestorableSession(linkcId: "X", cwd: "/tmp", title: "x"))
        // Recent, whole-second dates: old fixtures would age out of the reload below, and
        // ISO8601 persistence rounds to whole seconds.
        let base = Date().timeIntervalSince1970.rounded()
        let first = Date(timeIntervalSince1970: base - 7200)
        manifest.markEnded(linkcId: "X", at: first)
        manifest.markEnded(linkcId: "X", at: Date(timeIntervalSince1970: base - 3600))
        XCTAssertEqual(manifest.entries.first?.endedAt, first, "the first endedAt must win")
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.first?.endedAt, first, "and must be what was persisted")
    }
}
