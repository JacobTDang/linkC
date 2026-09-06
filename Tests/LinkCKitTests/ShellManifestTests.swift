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
        command: String? = nil,
        wasActiveOnQuit: Bool = false,
        detectedAgent: AgentKind? = nil,
        endedAt: Date? = nil
    ) -> RestorableShell {
        RestorableShell(
            id: id,
            cwd: cwd,
            title: title,
            command: command,
            wasActiveOnQuit: wasActiveOnQuit,
            detectedAgent: detectedAgent,
            endedAt: endedAt
        )
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

    func testRestorableShellBackwardsCompatibility() throws {
        let json = """
        {
            "id": "S-legacy",
            "cwd": "/tmp/legacy",
            "title": "Legacy Terminal"
        }
        """
        let data = Data(json.utf8)
        let shell = try JSONDecoder().decode(RestorableShell.self, from: data)

        XCTAssertEqual(shell.id, "S-legacy")
        XCTAssertEqual(shell.cwd, "/tmp/legacy")
        XCTAssertEqual(shell.title, "Legacy Terminal")
        XCTAssertNil(shell.command)
        XCTAssertFalse(shell.wasActiveOnQuit, "legacy records without wasActiveOnQuit must default to false")
        XCTAssertNil(shell.detectedAgent, "legacy records without detectedAgent must default to nil")
        XCTAssertNil(shell.endedAt)
    }

    func testRestorableShellRoundTripWithAgentAndActiveOnQuit() throws {
        let original = RestorableShell(
            id: "S-active",
            cwd: "/tmp/repo",
            title: "Active Dev Server",
            command: "npm run dev",
            wasActiveOnQuit: true,
            detectedAgent: .cursor,
            endedAt: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(RestorableShell.self, from: data)

        XCTAssertEqual(decoded.id, "S-active")
        XCTAssertEqual(decoded.cwd, "/tmp/repo")
        XCTAssertEqual(decoded.title, "Active Dev Server")
        XCTAssertEqual(decoded.command, "npm run dev")
        XCTAssertTrue(decoded.wasActiveOnQuit)
        XCTAssertEqual(decoded.detectedAgent, .cursor)
        XCTAssertNil(decoded.endedAt)
    }

    func testPruneRetainsMultipleActiveShellsInSameFolderAndCommand() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let s1 = entry("S1", cwd: "/repo/shared", title: "Terminal 1", command: nil, wasActiveOnQuit: true)
        let s2 = entry("S2", cwd: "/repo/shared", title: "Terminal 2", command: nil, wasActiveOnQuit: true)
        let s3 = entry("S3", cwd: "/repo/shared", title: "Terminal Old", command: nil, wasActiveOnQuit: false, endedAt: now.addingTimeInterval(-7200))
        let s4 = entry("S4", cwd: "/repo/shared", title: "Terminal New", command: nil, wasActiveOnQuit: false, endedAt: now.addingTimeInterval(-3600))

        let pruned = ShellManifest.prune([s1, s2, s3, s4], now: now)

        let retainedIds = Set(pruned.map(\.id))
        XCTAssertTrue(retainedIds.contains("S1"), "active shell S1 must be retained")
        XCTAssertTrue(retainedIds.contains("S2"), "active shell S2 must be retained")
        XCTAssertTrue(retainedIds.contains("S4"), "newest inactive shell S4 must be retained")
        XCTAssertFalse(retainedIds.contains("S3"), "older inactive shell S3 must be pruned")
    }
}
