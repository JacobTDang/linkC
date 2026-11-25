import CryptoKit
import XCTest
@testable import LinkCKit

final class CursorSessionReaderTests: XCTestCase {
    private typealias P = ProtobufFixtures
    private var dir: URL!
    private let cwd = "/made/up/folder"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func sqlite(_ path: String, _ sql: String) throws {
        let made = try LiveProcessRunner.runCapturingSync(executable: SQLiteCLI.executable, args: [path, sql], cwd: nil, timeout: 5)
        XCTAssertEqual(made.status, 0, made.stderr)
    }

    /// The root blob of a made-up chat: a long list of 32-byte ids in field 1, then the usage message
    /// in field 5, which holds the tokens used (1), the window (2) and a nested breakdown (3).
    private func rootBlob(used: UInt64?, window: UInt64?) -> [UInt8] {
        var usage: [UInt8] = []
        if let used { usage += P.varintField(1, used) }
        if let window { usage += P.varintField(2, window) }
        usage += P.bytesField(3, P.varintField(1, 5) + P.bytesField(3, [0x41]))
        return P.bytesField(1, [UInt8](repeating: 0xab, count: 32)) + P.bytesField(5, usage) + P.varintField(10, 1)
    }

    /// A made-up chat store under `root/chats/<md5(cwd)>/<chatId>/store.db`, returning its path.
    @discardableResult
    private func chatStore(
        root: String = ".cursor", folder: String? = nil, chatId: String = "chat-one", rootId: String = "root1",
        blob: [UInt8]? = nil, metaValue: String? = nil, writeBlob: Bool = true
    ) throws -> String {
        let chatDir = dir.appendingPathComponent("\(root)/chats/\(folder ?? md5(cwd))/\(chatId)")
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        let path = chatDir.appendingPathComponent("store.db").path
        let json = "{\"agentId\":\"\(chatId)\",\"latestRootBlobId\":\"\(rootId)\",\"mode\":\"default\"}"
        let value = metaValue ?? P.hex(Array(json.utf8))
        var sql = "create table blobs (id text primary key, data blob); create table meta (key text primary key, value text);"
        sql += " insert into meta values ('0', '\(value)');"
        if writeBlob {
            sql += " insert into blobs values ('\(rootId)', x'\(P.hex(blob ?? rootBlob(used: 1, window: 2)))');"
        }
        try sqlite(path, sql)
        return path
    }

    private func target(_ openFiles: [String], agent: AgentKind = .cursor) -> LiveSessionTarget {
        LiveSessionTarget(sessionId: "S1", agent: agent, cwd: cwd, openFiles: openFiles)
    }

    private func reader() -> CursorSessionReader {
        CursorSessionReader()
    }

    // MARK: - Context

    func testContextPercentIsTheTokensUsedOverTheWindowRounded() throws {
        // 1280 of 3000 is 42.67: rounded to 43, not cut to 42.
        let path = try chatStore(blob: rootBlob(used: 1280, window: 3000))
        XCTAssertEqual(try reader().read(target([path])).contextPercent, 43)
    }

    func testGrokReadsTheSameFormatUnderItsOwnConfigFolder() throws {
        let path = try chatStore(root: ".cursor-grok", blob: rootBlob(used: 100_000, window: 200_000))
        XCTAssertEqual(try reader().read(target([path], agent: .grok)).contextPercent, 50)
    }

    func testTheChatStoreIsFoundAmongOtherOpenFiles() throws {
        let path = try chatStore(blob: rootBlob(used: 1, window: 4))
        let open = ["/made/up/ai-code-tracking.db", path + "-wal", path + "-shm", path, "/made/up/other.txt"]
        XCTAssertEqual(try reader().read(target(open)).contextPercent, 25)
    }

    func testASessionWithNoChatStoreOpenReadsAsNothing() throws {
        let path = try chatStore()
        XCTAssertEqual(try reader().read(target([path + "-wal", "/made/up/ai-code-tracking.db"])), SessionLiveDetail())
        XCTAssertEqual(try reader().read(target([])), SessionLiveDetail())
    }

    func testAStoreDbOutsideAChatsFolderIsNotAChatStore() throws {
        let path = dir.appendingPathComponent("store.db").path
        try sqlite(path, "create table t(n int);")
        XCTAssertEqual(try reader().read(target([path])), SessionLiveDetail())
    }

    func testSeveralOpenChatStoresAreToldApartByTheFolderTheyAreFor() throws {
        let mine = try chatStore(chatId: "mine", blob: rootBlob(used: 50, window: 100))
        let other = try chatStore(folder: md5("/some/other/folder"), chatId: "other", blob: rootBlob(used: 10, window: 100))
        XCTAssertEqual(try reader().read(target([other, mine])).contextPercent, 50)
    }

    func testSeveralOpenChatStoresNoneOfThemForTheFolderCannotBeMatchedExactly() throws {
        let one = try chatStore(folder: md5("/one"), chatId: "one")
        let two = try chatStore(folder: md5("/two"), chatId: "two")
        XCTAssertEqual(try reader().read(target([one, two])), SessionLiveDetail())
    }

    func testAChatNotStartedYetHasNoContextToReport() throws {
        let path = try chatStore(rootId: "", writeBlob: false)
        XCTAssertEqual(try reader().read(target([path])), SessionLiveDetail())
    }

    func testARootBlobWithNothingInItHasNoContextToReport() throws {
        let path = try chatStore(blob: [])
        XCTAssertNil(try reader().read(target([path])).contextPercent)
    }

    func testUsageMissingItsTokensOrWindowHasNoContextToReport() throws {
        let noWindow = try chatStore(chatId: "no-window", blob: rootBlob(used: 10, window: nil))
        XCTAssertNil(try reader().read(target([noWindow])).contextPercent)
        let noUsed = try chatStore(chatId: "no-used", blob: rootBlob(used: nil, window: 100))
        XCTAssertNil(try reader().read(target([noUsed])).contextPercent)
        let zeroWindow = try chatStore(chatId: "zero-window", blob: rootBlob(used: 10, window: 0))
        XCTAssertNil(try reader().read(target([zeroWindow])).contextPercent)
    }

    func testAFullerThanFullWindowReadsAsFull() throws {
        let path = try chatStore(blob: rootBlob(used: 300, window: 200))
        XCTAssertEqual(try reader().read(target([path])).contextPercent, 100)
    }

    // MARK: - A record that is found but cannot be read

    private func assertReadThrows(_ path: String, containing reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try reader().read(target([path])), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription, file: file, line: line)
        }
    }

    func testAStoreThatIsNotADatabaseThrows() throws {
        let path = try chatStore()
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: path))
        assertReadThrows(path, containing: "sqlite3 could not read")
    }

    func testAStoreWithNoMetaRowThrows() throws {
        let path = try chatStore()
        try sqlite(path, "delete from meta;")
        assertReadThrows(path, containing: "no meta row")
    }

    func testAMetaRowThatIsNotHexThrows() throws {
        assertReadThrows(try chatStore(metaValue: "zz not hex"), containing: "not hex")
    }

    func testAMetaRowThatIsNotJSONThrows() throws {
        assertReadThrows(try chatStore(metaValue: P.hex(Array("not json".utf8))), containing: "not JSON")
    }

    func testAMetaRowWithoutARootBlobIdThrows() throws {
        assertReadThrows(try chatStore(metaValue: P.hex(Array("{\"mode\":\"default\"}".utf8))), containing: "latestRootBlobId")
    }

    func testARootBlobIdThatIsNotAnIdThrowsRatherThanReachTheQuery() throws {
        assertReadThrows(try chatStore(rootId: "x' or '1'='1", writeBlob: false), containing: "not a blob id")
    }

    func testARootBlobThatIsNotThereThrows() throws {
        assertReadThrows(try chatStore(writeBlob: false), containing: "root blob root1")
    }

    func testARootBlobThatIsNotProtobufThrows() throws {
        // A varint tag claiming field 1 holds 200 bytes, with 1 behind it.
        assertReadThrows(try chatStore(blob: [0x0a, 0xc8, 0x01, 0x00]), containing: "protobuf")
    }
}
