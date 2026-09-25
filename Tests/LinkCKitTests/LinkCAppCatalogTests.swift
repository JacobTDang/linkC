import XCTest
@testable import LinkCKit

@MainActor
final class LinkCAppCatalogTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func project(_ name: String, manifest: String?) throws -> String {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".linkc"), withIntermediateDirectories: true)
        if let manifest {
            try Data(manifest.utf8).write(to: folder.appendingPathComponent(LinkCAppManifest.relativePath))
        }
        return (folder.path as NSString).standardizingPath
    }

    private func setting(_ folder: String, _ name: String) -> LinkCAppSetting {
        LinkCAppSetting(folder: folder, manifest: LinkCAppManifest(name: name, start: ["a"], health: "/"))
    }

    func testAProjectManifestListsItsAppThenTheSettingsApps() throws {
        let circuit = try project("circuit", manifest: #"{"name": "Circuit", "start": ["a"], "health": "/"}"#)
        let apps = LinkCAppCatalog().apps(inProject: circuit, settings: [setting("/tools/notes", "Notes")])
        XCTAssertEqual(apps.map(\.name), ["Circuit", "Notes"])
        XCTAssertEqual(apps.map(\.source), [.project, .settings])
        XCTAssertEqual(apps[0].folder, circuit)
        XCTAssertEqual(try apps[0].manifest.get().name, "Circuit")
    }

    func testAProjectWithoutAManifestListsOnlyTheSettingsApps() throws {
        let plain = try project("plain", manifest: nil)
        XCTAssertEqual(LinkCAppCatalog().apps(inProject: plain, settings: [setting("/tools/notes", "Notes")]).map(\.name), ["Notes"])
    }

    func testAProjectAppHidesTheSettingsAppWithTheSameFolder() throws {
        let circuit = try project("circuit", manifest: #"{"name": "Circuit", "start": ["a"], "health": "/"}"#)
        let apps = LinkCAppCatalog().apps(inProject: circuit, settings: [setting(circuit + "/", "Old circuit")])
        XCTAssertEqual(apps.map(\.name), ["Circuit"])
    }

    func testABrokenManifestIsListedWithItsReason() throws {
        let broken = try project("broken", manifest: #"{"name": "Broken", "health": "/"}"#)
        let apps = LinkCAppCatalog().apps(inProject: broken, settings: [])
        XCTAssertEqual(apps.map(\.name), ["broken"], "a manifest that can't be used shows the folder's name")
        guard case .failure(let error) = apps[0].manifest else { return XCTFail("expected a failure") }
        XCTAssertTrue(error.localizedDescription.contains("\"start\""))
    }

    func testAnInvalidSettingsAppIsListedWithItsReason() {
        let bad = LinkCAppSetting(folder: "/tools/bad", manifest: LinkCAppManifest(name: "Bad", start: [], health: "/"))
        let apps = LinkCAppCatalog().apps(inProject: "/nowhere", settings: [bad])
        XCTAssertEqual(apps.map(\.name), ["Bad"])
        guard case .failure = apps[0].manifest else { return XCTFail("expected a failure") }
    }

    func testTheProjectManifestIsReadAtMostOncePerTTL() throws {
        let circuit = try project("circuit", manifest: #"{"name": "One", "start": ["a"], "health": "/"}"#)
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = LinkCAppCatalog(ttl: 2, now: { clock })
        XCTAssertEqual(catalog.apps(inProject: circuit, settings: []).map(\.name), ["One"])

        try Data(#"{"name": "Two", "start": ["a"], "health": "/"}"#.utf8)
            .write(to: URL(fileURLWithPath: circuit).appendingPathComponent(LinkCAppManifest.relativePath))
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(catalog.apps(inProject: circuit, settings: []).map(\.name), ["One"], "still cached")
        clock = clock.addingTimeInterval(1.5)
        XCTAssertEqual(catalog.apps(inProject: circuit, settings: []).map(\.name), ["Two"], "read again after the TTL")
    }
}
