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

        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rootTemp.path),
            "a crash leftover named as the staging names are, under the mod root, must be swept"
        )
    }

    /// Only a regular file named exactly as a staging temp is named (`.linkc-new-` and a UUID), in
    /// the mod root where staging happens, is the install's to delete. Everything else that has
    /// ".linkc-new-" in its name is the user's, or the engine's.
    func testOnlyAStagingTempIsSweptAndNothingElseWithTheSameWords() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "same"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let fm = FileManager.default
        let uuid = UUID().uuidString

        let kept: [(String, String)] = [
            ("notes.linkc-new-ideas.txt", "a user's file with the words in its name"),
            ("README.md.linkc-new-\(uuid)", "beside a shipped file: not where staging puts it"),
            (".linkc-new-notes", "in the root, but not named with a UUID"),
            (".linkc-new-\(uuid.lowercased())", "a UUID in the wrong case is not one it made"),
            ("deep/.linkc-new-\(uuid)", "nested: not where staging puts it"),
            (".claude-plugin/types/.linkc-new-\(uuid)", "under the generated types folder"),
            (".claude-plugin/types/x.linkc-new-y.d.ts", "in the generated types folder"),
        ]
        for (relative, text) in kept {
            let url = modRoot.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // A folder named like a temp, with a file in it, and a link named like one.
        let folderTemp = modRoot.appendingPathComponent(".linkc-new-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folderTemp, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folderTemp.appendingPathComponent("inside.txt"))
        let target = root.appendingPathComponent("link-target.txt")
        try Data("target".utf8).write(to: target)
        let linkTemp = modRoot.appendingPathComponent(".linkc-new-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: linkTemp, withDestinationURL: target)

        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()

        for (relative, text) in kept {
            XCTAssertEqual(
                try String(contentsOf: modRoot.appendingPathComponent(relative), encoding: .utf8), text,
                "\(relative) is not a staging temp"
            )
        }
        XCTAssertTrue(fm.fileExists(atPath: folderTemp.appendingPathComponent("inside.txt").path), "a folder is not a temp")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: linkTemp.path), target.path, "a link is not a temp")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
    }

    /// A temp that cannot be removed is said, with its name, and stops the install.
    func testALeftoverTempThatCannotBeRemovedIsReported() throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX write permissions, so this cannot be exercised as root")
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "same"])
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        let modRoot = installRoot.appendingPathComponent("linkc-agents", isDirectory: true)
        let tempName = ".linkc-new-\(UUID().uuidString)"
        try Data("orphan".utf8).write(to: modRoot.appendingPathComponent(tempName))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: modRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modRoot.path) }

        XCTAssertThrowsError(
            try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("linkc-agents"), message)
            XCTAssertTrue(message.contains(tempName), "names the file it could not remove: \(message)")
        }
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

    // MARK: - What the user has at a shipped path

    private func installed(_ relative: String) -> URL {
        installRoot.appendingPathComponent("linkc-agents").appendingPathComponent(relative)
    }

    @discardableResult
    private func install() throws -> [String] {
        try BundledMods(bundleModsDirectory: bundleMods, installDirectory: installRoot).install()
    }

    /// A shipped file does not replace a folder of the user's: `replaceItemAt` would delete it.
    func testAShippedFileWhereAnUnshippedFolderSitsIsRefusedAndTheFolderKept() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "old"])
        try install()
        try FileManager.default.createDirectory(at: installed("foo"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: installed("foo/user.txt"))
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "new", "foo": "a file now"])

        XCTAssertThrowsError(try install()) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("foo"), "names the folder: \(message)")
            XCTAssertTrue(message.contains("folder"), message)
            XCTAssertTrue(message.contains("Move or remove"), "says what to do: \(message)")
        }

        XCTAssertEqual(try String(contentsOf: installed("foo/user.txt"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: installed("README.md"), encoding: .utf8), "old", "nothing was changed")
    }

    /// A folder that holds only what linkC shipped is its own to turn into a file.
    func testAShippedFileMayReplaceAFolderThatHoldsOnlyWhatWasShipped() throws {
        try writeBundleMod(name: "linkc-agents", files: ["foo/bar.txt": "was nested"])
        try install()
        try FileManager.default.removeItem(at: bundleMods.appendingPathComponent("linkc-agents"))
        try writeBundleMod(name: "linkc-agents", files: ["foo": "a file now"])

        try install()

        XCTAssertEqual(try String(contentsOf: installed("foo"), encoding: .utf8), "a file now")
    }

    func testAFolderThatHoldsAFileOfTheUsersBesideWhatWasShippedIsKept() throws {
        try writeBundleMod(name: "linkc-agents", files: ["foo/bar.txt": "was nested"])
        try install()
        try Data("mine".utf8).write(to: installed("foo/user.txt"))
        try FileManager.default.removeItem(at: bundleMods.appendingPathComponent("linkc-agents"))
        try writeBundleMod(name: "linkc-agents", files: ["foo": "a file now"])

        XCTAssertThrowsError(try install())

        XCTAssertEqual(try String(contentsOf: installed("foo/user.txt"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: installed("foo/bar.txt"), encoding: .utf8), "was nested")
    }

    /// The user's link at a shipped path is theirs: left as it is, said once with the path and what
    /// to do, and the rest of the mod still updates. A throw each launch would stop it for good.
    func testAUsersLinkAtAShippedPathIsLeftAloneSaidOnceAndTheRestUpdates() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "old", "other.md": "old"])
        try install()
        let mine = root.appendingPathComponent("my-readme.md")
        try Data("my own".utf8).write(to: mine)
        try FileManager.default.removeItem(at: installed("README.md"))
        try FileManager.default.createSymbolicLink(at: installed("README.md"), withDestinationURL: mine)
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "new", "other.md": "new"])

        for launch in 1...2 {
            let notices = try install()

            XCTAssertEqual(notices.count, 1, "launch \(launch): \(notices)")
            XCTAssertTrue(notices[0].contains("linkc-agents/README.md"), "names the path: \(notices[0])")
            XCTAssertTrue(notices[0].contains("link"), notices[0])
            XCTAssertTrue(notices[0].contains("Remove the link"), "says what to do: \(notices[0])")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed("README.md").path), mine.path)
            XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "my own")
            XCTAssertEqual(try String(contentsOf: installed("other.md"), encoding: .utf8), "new")
        }
    }

    func testAUsersLinkAtAShippedPathNeverInstalledIsLeftAloneToo() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "new", "other.md": "new"])
        let mine = root.appendingPathComponent("my-readme.md")
        try Data("my own".utf8).write(to: mine)
        try FileManager.default.createDirectory(
            at: installed("README.md").deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installed("README.md"), withDestinationURL: mine)

        let notices = try install()

        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "my own")
        XCTAssertEqual(try String(contentsOf: installed("other.md"), encoding: .utf8), "new")
    }

    /// A file linkC no longer ships, which the user has since linked to their own, is not linkC's to delete.
    func testADroppedFileThatTheUserHasLinkedIsLeftAloneWithoutAThrow() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "same", "old.md": "old"])
        try install()
        let mine = root.appendingPathComponent("my-old.md")
        try Data("my own".utf8).write(to: mine)
        try FileManager.default.removeItem(at: installed("old.md"))
        try FileManager.default.createSymbolicLink(at: installed("old.md"), withDestinationURL: mine)
        try FileManager.default.removeItem(at: bundleMods.appendingPathComponent("linkc-agents"))
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "same"])

        try install()

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed("old.md").path), mine.path)
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "my own")
    }

    /// A folder of the user's that is a link: a shipped path under it would be written outside the
    /// mod folder. Refused, naming the link and what to do; nothing is written.
    func testAShippedPathUnderAFolderLinkOfTheUsersIsRefused() throws {
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "old"])
        try install()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installed("lib"), withDestinationURL: outside)
        try writeBundleMod(name: "linkc-agents", files: ["README.md": "new", "lib/x.js": "shipped", "lib/deep/y.js": "shipped"])

        XCTAssertThrowsError(try install()) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("lib"), "names the link: \(message)")
            XCTAssertTrue(message.contains("link"), message)
            XCTAssertTrue(message.contains("Remove the link"), "says what to do: \(message)")
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [], "nothing was written through it")
        XCTAssertEqual(try String(contentsOf: installed("README.md"), encoding: .utf8), "old", "nothing was changed")
    }

    /// The notices are said when they are new: the ones said before are not said again, and one that
    /// goes and comes back is new again.
    func testANoticeIsNewOnlyWhenItWasNotSaidBefore() {
        XCTAssertEqual(BundledMods.unsaid(["a", "b"], saidBefore: ["a"]), ["b"])
        XCTAssertEqual(BundledMods.unsaid(["a"], saidBefore: ["a"]), [])
        XCTAssertEqual(BundledMods.unsaid([], saidBefore: ["a"]), [])
        XCTAssertEqual(BundledMods.unsaid(["a"], saidBefore: []), ["a"])
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
