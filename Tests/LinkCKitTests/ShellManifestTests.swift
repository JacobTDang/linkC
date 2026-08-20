import XCTest
@testable import LinkCKit

/// Dev terminals survive quitting linkC: the manifest persists what a shell needs to be
/// re-opened (folder, title, command for command-mode shells), with the same retention
/// discipline as the session manifest — orphans stamped at load, week-old entries dropped,
/// one entry per folder+command.
final class ShellManifestTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-shells-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(
        _ id: String, cwd: String = "/tmp/proj", title: String = "proj",
        command: String? = nil, endedAt: Date? = nil
    ) -> RestorableShell {
        RestorableShell(id: id, cwd: cwd, title: title, command: command, endedAt: endedAt)
    }

    func testRoundTripSaveLoad() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ended = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)

        let manifest = ShellManifest(directory: dir)
        manifest.upsert(entry("S1", cwd: "/a", title: "a", endedAt: ended))
        manifest.upsert(entry("S2", cwd: "/b", title: "logs", command: "docker logs -f x", endedAt: ended))

        let reloaded = ShellManifest(directory: dir)
        XCTAssertEqual(Set(reloaded.entries.map(\.id)), ["S1", "S2"])
        let logs = reloaded.entries.first { $0.id == "S2" }
        XCTAssertEqual(logs?.command, "docker logs -f x", "command-mode shells relaunch as themselves")
        XCTAssertEqual(logs?.cwd, "/b")
    }

    func testMissingAndCorruptLoadEmpty() throws {
        XCTAssertTrue(ShellManifest(directory: tempDir()).entries.isEmpty)

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("shells.json"))
        XCTAssertTrue(ShellManifest(directory: dir).entries.isEmpty, "a corrupt manifest must not crash the app")
    }

    /// Retention mirrors the session manifest: a shell still marked live belongs to a dead
    /// run (loading proves it), week-old entries drop, and each folder+command keeps one.
    func testLoadStampsOrphansAgesOutAndDedupes() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let seed = ShellManifest(directory: dir)
        seed.upsert(entry("aged", cwd: "/a", endedAt: now.addingTimeInterval(-8 * 24 * 3600)))
        seed.upsert(entry("dupOld", cwd: "/b", endedAt: now.addingTimeInterval(-7200)))
        seed.upsert(entry("dupNew", cwd: "/b", endedAt: now.addingTimeInterval(-60)))
        // Same folder, different command — a distinct thing to restore, not a duplicate.
        seed.upsert(entry("cmd", cwd: "/b", command: "npm run dev", endedAt: now.addingTimeInterval(-60)))
        seed.upsert(entry("orphan", cwd: "/c"))

        let reloaded = ShellManifest(directory: dir, now: now)
        XCTAssertEqual(Set(reloaded.entries.map(\.id)), ["dupNew", "cmd", "orphan"])
        XCTAssertEqual(reloaded.entries.first { $0.id == "orphan" }?.endedAt, now,
                       "a dead run's live entry is stamped at load")

        // The pruned set is persisted — a third open sees the same thing.
        XCTAssertEqual(Set(ShellManifest(directory: dir, now: now).entries.map(\.id)),
                       ["dupNew", "cmd", "orphan"])
    }

    func testRemoveForgetsEntry() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = ShellManifest(directory: dir)
        manifest.upsert(entry("S1"))
        manifest.upsert(entry("S2", cwd: "/other"))

        manifest.remove(id: "S1")

        XCTAssertEqual(manifest.entries.map(\.id), ["S2"])
        XCTAssertEqual(ShellManifest(directory: dir).entries.map(\.id), ["S2"], "persisted")
    }
}
