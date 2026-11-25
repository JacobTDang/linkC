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
