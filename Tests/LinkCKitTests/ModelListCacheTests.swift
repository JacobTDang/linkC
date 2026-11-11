import XCTest
@testable import LinkCKit

final class ModelListCacheTests: XCTestCase {
    private var dir: URL!
    private var cache: ModelListCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-model-list-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache = ModelListCache(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    func testMissingFileReadsAsEmpty() throws {
        XCTAssertEqual(try cache.read(), [:])
    }

    func testRoundTrip() throws {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let lists: [AgentKind: AgentModelList] = [
            .agy: AgentModelList(
                models: [ListedModel(id: "gemini-3.8-flash-medium", name: "Flash")],
                fetchedAt: fetched,
                error: nil),
            .opencode: AgentModelList(
                models: [ListedModel(id: "opencode/big-pickle", name: "opencode/big-pickle")],
                fetchedAt: fetched,
                error: "offline"),
        ]
        try cache.write(lists)
        let read = try cache.read()
        XCTAssertEqual(read[.agy]?.models, lists[.agy]?.models)
        XCTAssertEqual(read[.agy]?.fetchedAt, fetched)
        XCTAssertNil(read[.agy]?.error)
        XCTAssertEqual(read[.opencode]?.error, "offline")
        XCTAssertEqual(read[.opencode]?.models.map(\.id), ["opencode/big-pickle"])
    }

    func testCorruptFileThrows() throws {
        try "{not-json".write(to: cache.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try cache.read())
    }

    func testUnknownAgentKeyIsSkipped() throws {
        let json = """
        {"agy":{"models":[{"id":"gemini-3.8-flash-medium","name":"Flash"}],"fetchedAt":0},"future-agent":{"models":[]}}
        """
        try json.write(to: cache.url, atomically: true, encoding: .utf8)
        let read = try cache.read()
        XCTAssertEqual(read.keys.sorted(by: { $0.rawValue < $1.rawValue }), [.agy])
        XCTAssertEqual(read[.agy]?.models.map(\.id), ["gemini-3.8-flash-medium"])
    }

    func testAvailableMergesCachedOrFixedWithTier() {
        let lists: [AgentKind: AgentModelList] = [
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                ],
                fetchedAt: Date(),
                error: nil),
        ]
        var settings = AgentModelSettings.seeded
        settings.setModel("hand-typed-id", for: .agy, tier: .deep)
        let available = ModelListCache.available(for: .agy, lists: lists, settings: settings)
        XCTAssertEqual(available.map(\.id), [
            "gemini-3.8-flash-medium",
            "claude-opus-4-6-thinking",
            "gemini-3.8-flash-low",
            "hand-typed-id",
        ])
    }

    func testAvailableUsesFixedListWhenNoCache() {
        let available = ModelListCache.available(for: .claude, lists: [:], settings: .seeded)
        XCTAssertEqual(available.map(\.id), ["haiku", "sonnet", "opus"])
    }

    func testAvailableDedupesTierIdsCaseInsensitively() {
        let lists: [AgentKind: AgentModelList] = [
            .claude: AgentModelList(
                models: [ListedModel(id: "Sonnet", name: "Sonnet")],
                fetchedAt: nil,
                error: nil),
        ]
        let available = ModelListCache.available(for: .claude, lists: lists, settings: .seeded)
        XCTAssertEqual(available.map(\.id), ["Sonnet", "haiku", "opus"])
    }
}
