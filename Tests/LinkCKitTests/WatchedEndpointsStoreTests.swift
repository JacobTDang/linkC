import XCTest
@testable import LinkCKit

/// The user-supplied watch list: usable entries load, unusable ones are skipped rather
/// than turned into probes, and a missing or corrupt file is simply "nothing to watch".
final class WatchedEndpointsStoreTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-endpoints-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ json: String, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("endpoints.json"))
    }

    func testLoadsUsableEntries() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("""
        [{"label": "mp3 server", "url": "https://music.example.com/health"},
         {"label": "api", "url": "http://10.0.0.5:8080/healthz"}]
        """, to: dir)

        let endpoints = WatchedEndpointsStore(directory: dir).load()
        XCTAssertEqual(endpoints.map(\.label), ["mp3 server", "api"])
        XCTAssertEqual(endpoints[0].url.absoluteString, "https://music.example.com/health")
        XCTAssertEqual(Set(endpoints.map(\.id)).count, 2, "ids are distinct per URL")
    }

    /// Plain http is deliberately allowed, not an oversight: the mp3 server is watched
    /// over http because its HTTPS front door only serves named sites and refuses a
    /// handshake aimed at the bare IP. Tightening this to https-only would silently stop
    /// watching it.
    func testPlainHTTPIsAllowed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"[{"label": "audio-1", "url": "http://203.0.113.10/"}]"#, to: dir)

        let endpoints = WatchedEndpointsStore(directory: dir).load()
        XCTAssertEqual(endpoints.map(\.label), ["audio-1"])
        XCTAssertEqual(endpoints.first?.url.scheme, "http")
    }

    /// A health check must stay a network probe: a file:// or other scheme in the config
    /// would turn "monitoring" into reading local files.
    func testRejectsNonHTTPSchemesAndIncompleteEntries() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("""
        [{"label": "sneaky", "url": "file:///etc/passwd"},
         {"label": "ftp", "url": "ftp://example.com/x"},
         {"label": "", "url": "https://example.com"},
         {"label": "no url"},
         {"label": "hostless", "url": "https:///nothing"},
         {"label": "good", "url": "https://ok.example.com"}]
        """, to: dir)

        let endpoints = WatchedEndpointsStore(directory: dir).load()
        XCTAssertEqual(endpoints.map(\.label), ["good"],
                       "only a complete http(s) entry with a host is watchable")
    }

    /// Two entries pointing at the same URL are two watched services. Sharing an id would
    /// make SwiftUI drop a row and the monitor's result map discard one probe.
    func testDuplicateURLsKeepDistinctIds() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("""
        [{"label": "primary", "url": "https://same.example.com/health"},
         {"label": "canary", "url": "https://same.example.com/health"}]
        """, to: dir)

        let endpoints = WatchedEndpointsStore(directory: dir).load()
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(Set(endpoints.map(\.id)).count, 2, "ids must not collide")
    }

    /// Ids must survive an edit elsewhere in the file: if inserting a line above renamed
    /// every id below it, those services would lose their history and a subsequent outage
    /// would be treated as a fresh baseline and never announced.
    func testIdsAreStableWhenOtherEntriesMove() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WatchedEndpointsStore(directory: dir)

        try write(#"[{"label": "mp3", "url": "https://music.example.com/health"}]"#, to: dir)
        let before = store.load().first?.id

        // The user adds a service ABOVE the existing one.
        try write("""
        [{"label": "new", "url": "https://new.example.com"},
         {"label": "mp3", "url": "https://music.example.com/health"}]
        """, to: dir)
        let after = store.load().first { $0.label == "mp3" }?.id

        XCTAssertEqual(before, after, "an unrelated edit must not re-identify a service")
    }

    func testMissingAndCorruptAreEmptyNotFatal() throws {
        XCTAssertTrue(WatchedEndpointsStore(directory: tempDir()).load().isEmpty)

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("not json at all", to: dir)
        XCTAssertTrue(WatchedEndpointsStore(directory: dir).load().isEmpty)
    }

    /// "reveal" in Settings has to land on a real file — and the seed must be an empty
    /// list, never a placeholder entry that would be probed and alert about a service
    /// that never existed.
    func testEnsureExistsSeedsAnEmptyList() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WatchedEndpointsStore(directory: dir)

        let path = try store.ensureExists()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(store.load().isEmpty, "a seeded file watches nothing")

        // Idempotent: it must not clobber a list the user already filled in.
        try write(#"[{"label": "mine", "url": "https://mine.example.com"}]"#, to: dir)
        _ = try store.ensureExists()
        XCTAssertEqual(store.load().map(\.label), ["mine"])
    }
}
