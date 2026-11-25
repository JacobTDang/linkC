import XCTest
@testable import LinkCKit

final class BundledModsTests: XCTestCase {
    private var root: URL!
    private var bundleMods: URL!
    private var installRoot: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-bundled-mods-\(UUID().uuidString)", isDirectory: true)
        bundleMods = root.appendingPathComponent("bundle/mods", isDirectory: true)
        installRoot = root.appendingPathComponent("support/mods", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testFreshInstallCopiesShippedFiles() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "hooks/hooks.json": #"{"hooks":[]}"#,
                "README.md": "hello",
            ]
        )

        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("hooks/hooks.json"), encoding: .utf8),
            #"{"hooks":[]}"#
        )
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("README.md"), encoding: .utf8),
            "hello"
        )
    }

    func testEngineTypesDirectoryIsKept() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "v1"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let typesFile = modRoot.appendingPathComponent(".claude-plugin/types/generated.d.ts")
        try FileManager.default.createDirectory(
            at: typesFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: typesFile)
        // Even a stale manifest that names the engine file must not cause a delete.
        let manifest = try JSONEncoder().encode([
            "README.md",
            ".claude-plugin/types/generated.d.ts",
        ])
        try manifest.write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "v2"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertEqual(try String(contentsOf: typesFile, encoding: .utf8), "generated")
    }

    func testUnwritableTargetIsReported() throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX write permissions, so this cannot be exercised as root")
        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "hello"]
        )
        // Parent exists but is not writable — install must fail loud.
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: installRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: installRoot.path
            )
        }

        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(
                message.contains("Couldn't install the linkc-agents mod"),
                "expected a clear install failure, got: \(message)"
            )
        }
    }

    func testHostileManifestEntriesAreRejectedAndDeleteNothing() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "safe"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let typesFile = modRoot.appendingPathComponent(".claude-plugin/types/generated.d.ts")
        try FileManager.default.createDirectory(
            at: typesFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: typesFile)

        let victim = root.appendingPathComponent("victim.txt")
        try Data("alive".utf8).write(to: victim)

        for hostile in ["../victim.txt", "/tmp/abs-victim", ""] {
            let poisoned = try JSONEncoder().encode(["README.md", hostile])
            try poisoned.write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

            XCTAssertThrowsError(
                try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install(),
                "hostile entry \(hostile.debugDescription) must fail loud"
            ) { error in
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                XCTAssertTrue(
                    message.contains("Couldn't install the linkc-agents mod"),
                    "expected a clear install failure for \(hostile.debugDescription), got: \(message)"
                )
            }

            XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "alive")
            XCTAssertTrue(FileManager.default.fileExists(atPath: modRoot.path), "mod folder must remain")
            XCTAssertEqual(try String(contentsOf: typesFile, encoding: .utf8), "generated")
            XCTAssertEqual(
                try String(contentsOf: modRoot.appendingPathComponent("README.md"), encoding: .utf8),
                "safe"
            )
        }
    }

    func testFileDroppedFromBundleIsRemoved() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "hooks/keep.tsx": "keep",
                "hooks/drop.tsx": "drop",
            ]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        try FileManager.default.removeItem(
            at: bundleMods.appendingPathComponent("linkc-agents/hooks/drop.tsx")
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installed.appendingPathComponent("hooks/keep.tsx").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installed.appendingPathComponent("hooks/drop.tsx").path)
        )
    }

    func testMidwayInstallFailureLeavesOldVersionIntact() throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX write permissions, so this cannot be exercised as root")
        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "hooks/keep.tsx": "old-hooks",
                "skills/keep.md": "old-skills",
            ]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let skillsDir = installed.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: skillsDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skillsDir.path)
        }

        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "hooks/keep.tsx": "new-hooks",
                "skills/keep.md": "new-skills",
            ]
        )
        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        )

        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("hooks/keep.tsx"), encoding: .utf8),
            "old-hooks",
            "a failed update must not leave a mixed version"
        )
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("skills/keep.md"), encoding: .utf8),
            "old-skills"
        )
    }

    func testChangedFileIsReplaced() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "old"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "new"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents/README.md")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "new")
    }

    func testUnchangedCopyLeavesModificationTimeAlone() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "same"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installedFile = installRoot
            .appendingPathComponent("linkc-agents/README.md")
        // Stamp a distinctive mtime: a rewrite from the bundle would replace it.
        let stamped = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: stamped], ofItemAtPath: installedFile.path
        )

        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let after = try FileManager.default.attributesOfItem(atPath: installedFile.path)[.modificationDate] as! Date
        XCTAssertEqual(after, stamped)
    }

    // MARK: - Helpers

    private func writeBundleMod(name: String, files: [String: String]) throws {
        let modRoot = bundleMods.appendingPathComponent(name, isDirectory: true)
        for (relative, contents) in files {
            let url = modRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
    }
}
