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

    func testBundledTypesFolderIsNotInstalled() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "README.md": "shipped",
                ".claude-plugin/types/from-bundle.d.ts": "must-not-copy",
            ]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("README.md"), encoding: .utf8),
            "shipped"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installed.appendingPathComponent(".claude-plugin/types/from-bundle.d.ts").path
            ),
            "the types-prefix skip must leave bundle types uninstalled"
        )
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

        for hostile in ["../victim.txt", "/tmp/abs-victim", "", ".", "./"] {
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

    func testDotEntryDoesNotDeleteModFolder() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "safe"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let typesFile = modRoot.appendingPathComponent(".claude-plugin/types/generated.d.ts")
        try FileManager.default.createDirectory(
            at: typesFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: typesFile)
        try JSONEncoder().encode(["README.md", "."])
            .write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modRoot.path))
        XCTAssertEqual(try String(contentsOf: typesFile, encoding: .utf8), "generated")
    }

    func testEngineTypesWithoutTrailingSlashIsNotPruned() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "v1"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let typesFile = modRoot.appendingPathComponent(".claude-plugin/types/generated.d.ts")
        try FileManager.default.createDirectory(
            at: typesFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: typesFile)
        try JSONEncoder().encode(["README.md", ".claude-plugin/types"])
            .write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        try writeBundleMod(name: "linkc-agents", files: ["README.md": "v2"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertEqual(try String(contentsOf: typesFile, encoding: .utf8), "generated")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: typesFile.deletingLastPathComponent().path),
            "engine types directory must survive a slash-less manifest entry"
        )
    }

    func testEngineTypesCaseInsensitiveIsNotPruned() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "v1"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let typesFile = modRoot.appendingPathComponent(".claude-plugin/types/generated.d.ts")
        try FileManager.default.createDirectory(
            at: typesFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: typesFile)
        try JSONEncoder().encode(["README.md", ".claude-plugin/Types/generated.d.ts"])
            .write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        try writeBundleMod(name: "linkc-agents", files: ["README.md": "v2"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertEqual(try String(contentsOf: typesFile, encoding: .utf8), "generated")
    }

    func testDirectoryManifestEntryIsNotRemovedRecursively() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "safe"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let userdata = modRoot.appendingPathComponent("userdata", isDirectory: true)
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        let keep = userdata.appendingPathComponent("keep.txt")
        try Data("user".utf8).write(to: keep)
        try JSONEncoder().encode(["README.md", "userdata/"])
            .write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        try writeBundleMod(name: "linkc-agents", files: ["README.md": "safe"])
        // May reject the trailing-slash entry or skip the directory — either way userdata stays.
        _ = try? BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: userdata.path))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "user")
    }

    /// "userdata" without a trailing slash passes the path check, so it reaches the prune. Only
    /// regular files are pruned: the folder and what is inside it stay.
    func testADirectoryEntryWithoutATrailingSlashIsNotPruned() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "safe"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let userdata = modRoot.appendingPathComponent("userdata", isDirectory: true)
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        let keep = userdata.appendingPathComponent("keep.txt")
        try Data("user".utf8).write(to: keep)
        try JSONEncoder().encode(["README.md", "userdata"])
            .write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        XCTAssertNoThrow(try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install())

        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "user")
    }

    /// A copy that fails after writing part of its temp leaves no temp behind: each temp is
    /// tracked before its copy starts. (A real copy of an unreadable source fails before it
    /// creates anything, so the partial temp comes from the copy seam.)
    func testACopyThatFailsPartwayLeavesNoTemp() throws {
        try writeBundleMod(name: "linkc-agents", files: ["a.txt": "old-a", "b.txt": "old-b"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        try writeBundleMod(name: "linkc-agents", files: ["a.txt": "new-a", "b.txt": "new-b"])
        let failing = BundledMods(
            bundleModsDirectory: bundleMods, installDirectory: installRoot,
            copyFile: { from, to in
                guard from.lastPathComponent == "b.txt" else {
                    return try FileManager.default.copyItem(at: from, to: to)
                }
                try Data("partial".utf8).write(to: to)
                throw CocoaError(.fileWriteOutOfSpace)
            })

        XCTAssertThrowsError(try failing.install())

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let temps = try FileManager.default.contentsOfDirectory(atPath: modRoot.path).filter { $0.hasPrefix(".linkc-new-") }
        XCTAssertEqual(temps, [], "a failed copy's partial temp is removed")
        XCTAssertEqual(try String(contentsOf: modRoot.appendingPathComponent("a.txt"), encoding: .utf8), "old-a")
    }

    func testManifestPathThroughSymlinkIsRejected() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "safe"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.txt")
        try Data("alive".utf8).write(to: victim)
        let link = modRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try JSONEncoder().encode(["README.md", "link/victim.txt"])
            .write(to: modRoot.appendingPathComponent(".linkc-shipped.json"))

        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        )
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "alive")
    }

    func testDoubleDotInFilenameIsAllowed() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: ["lib/a..b.js": "ok"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents/lib/a..b.js")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "ok")

        // A later launch reloads the manifest — must not treat ".." inside a component as hostile.
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "ok")
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

    func testLeftoverStageTempsAreSweptAtStart() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "same"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let rootTemp = modRoot.appendingPathComponent(".linkc-new-\(UUID().uuidString)")
        try Data("orphan".utf8).write(to: rootTemp)
        let besideTemp = URL(
            fileURLWithPath: modRoot.appendingPathComponent("README.md").path
                + ".linkc-new-\(UUID().uuidString)"
        )
        try Data("orphan-beside".utf8).write(to: besideTemp)

        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rootTemp.path),
            "crash leftovers named .linkc-new-* under the mod root must be swept"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: besideTemp.path),
            "crash leftovers named *.linkc-new-* beside a shipped file must be swept"
        )
    }

    func testFailedUpdateDoesNotClearBlockingFileDuringStaging() throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX write permissions, so this cannot be exercised as root")
        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "foo": "was-a-file",
                "skills/keep.md": "old-skills",
            ]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)

        try FileManager.default.removeItem(at: bundleMods.appendingPathComponent("linkc-agents"))
        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "foo/bar.txt": "now-nested",
                "skills/keep.md": "new-skills",
            ]
        )
        // Staging sorts paths: foo/bar.txt copies first, then skills/keep.md. Make the later
        // source unreadable so staging fails before commit clears the blocking file.
        let sourceSkills = bundleMods.appendingPathComponent("linkc-agents/skills/keep.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourceSkills.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceSkills.path)
        }

        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        )

        let foo = installed.appendingPathComponent("foo")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foo.path, isDirectory: &isDir) && !isDir.boolValue,
            "a failed staging pass must not clear a shipped file that blocks a new folder"
        )
        XCTAssertEqual(try String(contentsOf: foo, encoding: .utf8), "was-a-file")
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("skills/keep.md"), encoding: .utf8),
            "old-skills"
        )
    }

    func testMidwayStagingFailureLeavesOldVersionIntact() throws {
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

        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "hooks/keep.tsx": "new-hooks",
                "skills/keep.md": "new-skills",
            ]
        )
        // Fail while staging the later sorted path so commit never runs.
        let sourceSkills = bundleMods.appendingPathComponent("linkc-agents/skills/keep.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourceSkills.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceSkills.path)
        }
        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        )

        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("hooks/keep.tsx"), encoding: .utf8),
            "old-hooks",
            "a failed staging pass must not swap any installed file"
        )
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("skills/keep.md"), encoding: .utf8),
            "old-skills"
        )
    }

    func testCommitPhaseFailureLeavesAlreadySwappedFileWhole() throws {
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

        // The set is not a transaction: hooks may already be the new whole file.
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("hooks/keep.tsx"), encoding: .utf8),
            "new-hooks"
        )
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("skills/keep.md"), encoding: .utf8),
            "old-skills"
        )
    }

    func testShippedFileInTheWayOfAFolderIsRemoved() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: ["foo": "was-a-file"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installed.appendingPathComponent("foo").path)
        )

        try FileManager.default.removeItem(at: bundleMods.appendingPathComponent("linkc-agents"))
        try writeBundleMod(
            name: "linkc-agents",
            files: ["foo/bar.txt": "now-nested"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("foo/bar.txt"), encoding: .utf8),
            "now-nested"
        )
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.appendingPathComponent("foo").path,
                isDirectory: &isDir
            ) && isDir.boolValue
        )
    }

    func testUnshippedFileInTheWayOfAFolderIsLeftAlone() throws {
        try writeBundleMod(
            name: "linkc-agents",
            files: ["README.md": "ok"]
        )
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        let installed = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let blocker = installed.appendingPathComponent("foo")
        try Data("user-owned".utf8).write(to: blocker)

        try writeBundleMod(
            name: "linkc-agents",
            files: [
                "README.md": "ok",
                "foo/bar.txt": "nested",
            ]
        )
        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        )
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "user-owned")
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
