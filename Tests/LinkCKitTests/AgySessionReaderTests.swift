import XCTest
@testable import LinkCKit

final class AgySessionReaderTests: XCTestCase {
    private typealias P = ProtobufFixtures
    private var root: URL!
    private let conversation = "11111111-2222-3333-4444-555555555555"
    private let other = "66666666-7777-8888-9999-000000000000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-agy-\(UUID().uuidString)/antigravity-cli")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("presence"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func sqlite(_ path: String, _ sql: String) throws {
        let made = try LiveProcessRunner.runCapturingSync(executable: SQLiteCLI.executable, args: [path, sql], cwd: nil, timeout: 5)
        XCTAssertEqual(made.status, 0, made.stderr)
    }

    /// A made-up `gen_metadata` row: the context message sits at 1.9.10, holding the tokens used (1)
    /// and the window (4), among fields the reader has no use for.
    private func row(used: UInt64?, window: UInt64?) -> [UInt8] {
        var context = P.bytesField(3, [0x41, 0x42])
        if let used { context += P.varintField(1, used) }
        if let window { context += P.varintField(4, window) }
        let nine = P.varintField(1, 5) + P.bytesField(10, context)
        return P.bytesField(2, [0x01]) + P.bytesField(4, [0x61]) + P.bytesField(1, P.varintField(1, 248) + P.bytesField(9, nine))
    }

    /// A made-up conversation: its presence lock and its database, returning the lock's path, the file
    /// a running agy holds open.
    @discardableResult
    private func makeConversation(_ id: String? = nil, rows: [(idx: Int, data: [UInt8])], makeDatabase: Bool = true) throws -> String {
        let id = id ?? conversation
        let lock = root.appendingPathComponent("presence/\(id).lock")
        try Data().write(to: lock)
        if makeDatabase {
            var sql = "create table gen_metadata (idx integer, data blob, size integer not null default 0, primary key (idx));"
            for row in rows {
                sql += " insert into gen_metadata (idx, data) values (\(row.idx), x'\(P.hex(row.data))');"
            }
            try sqlite(root.appendingPathComponent("conversations/\(id).db").path, sql)
        }
        return lock.path
    }

    private func target(_ openFiles: [String]) -> LiveSessionTarget {
        LiveSessionTarget(sessionId: "S1", agent: .agy, cwd: "/made/up/folder", openFiles: openFiles)
    }

    func testContextPercentIsTheTokensUsedOverTheWindowOfTheLatestRow() throws {
        // Written out of order: the highest idx wins, not the last written. 4215 of 10000 is 42.15.
        let lock = try makeConversation(rows: [
            (idx: 3, data: row(used: 4215, window: 10_000)),
            (idx: 1, data: row(used: 9000, window: 10_000)),
            (idx: 2, data: row(used: 100, window: 10_000)),
        ])
        XCTAssertEqual(try AgySessionReader().read(target([lock])).contextPercent, 42)
    }

    func testTheConversationIsFoundAmongOtherOpenFiles() throws {
        let lock = try makeConversation(rows: [(idx: 1, data: row(used: 1, window: 4))])
        let open = [root.appendingPathComponent("history.jsonl").path, root.appendingPathComponent("brain/\(conversation)").path,
                    lock, root.appendingPathComponent("conversation_summaries.db").path]
        XCTAssertEqual(try AgySessionReader().read(target(open)).contextPercent, 25)
    }

    func testASessionHoldingNoConversationLockReadsAsNothing() throws {
        try makeConversation(rows: [(idx: 1, data: row(used: 1, window: 4))])
        XCTAssertEqual(try AgySessionReader().read(target([root.appendingPathComponent("brain/\(conversation)").path])), SessionLiveDetail())
        XCTAssertEqual(try AgySessionReader().read(target([])), SessionLiveDetail())
    }

    func testALockFileThatIsNotInThePresenceFolderOrNamedForAConversationIsNotOne() throws {
        try makeConversation(rows: [(idx: 1, data: row(used: 1, window: 4))])
        let elsewhere = root.appendingPathComponent("\(conversation).lock").path
        let notAnId = root.appendingPathComponent("presence/settings.lock").path
        XCTAssertEqual(try AgySessionReader().read(target([elsewhere, notAnId])), SessionLiveDetail())
    }

    func testTwoConversationsHeldOpenCannotBeMatchedExactly() throws {
        let one = try makeConversation(rows: [(idx: 1, data: row(used: 1, window: 4))])
        let two = try makeConversation(other, rows: [(idx: 1, data: row(used: 3, window: 4))])
        XCTAssertEqual(try AgySessionReader().read(target([one, two])), SessionLiveDetail())
    }

    func testAConversationWhoseDatabaseIsNotWrittenYetReadsAsNothing() throws {
        let lock = try makeConversation(rows: [], makeDatabase: false)
        XCTAssertEqual(try AgySessionReader().read(target([lock])), SessionLiveDetail())
    }

    func testAConversationWithNoRowsYetHasNoContextToReport() throws {
        let lock = try makeConversation(rows: [])
        XCTAssertEqual(try AgySessionReader().read(target([lock])), SessionLiveDetail())
    }

    func testARowWithoutContextHasNoContextToReport() throws {
        let noContext = P.bytesField(1, P.varintField(1, 248) + P.bytesField(9, P.varintField(1, 5)))
        let lock = try makeConversation(rows: [(idx: 1, data: noContext)])
        XCTAssertNil(try AgySessionReader().read(target([lock])).contextPercent)
    }

    func testContextMissingItsTokensOrWindowHasNoContextToReport() throws {
        let noWindow = try makeConversation(rows: [(idx: 1, data: row(used: 10, window: nil))])
        XCTAssertNil(try AgySessionReader().read(target([noWindow])).contextPercent)
        try FileManager.default.removeItem(at: root.appendingPathComponent("conversations/\(conversation).db"))
        let noUsed = try makeConversation(rows: [(idx: 1, data: row(used: nil, window: 100))])
        XCTAssertNil(try AgySessionReader().read(target([noUsed])).contextPercent)
        try FileManager.default.removeItem(at: root.appendingPathComponent("conversations/\(conversation).db"))
        let zeroWindow = try makeConversation(rows: [(idx: 1, data: row(used: 10, window: 0))])
        XCTAssertNil(try AgySessionReader().read(target([zeroWindow])).contextPercent)
    }

    // MARK: - A conversation agy has open

    private struct Row: Decodable { let idx: Int }

    private var database: String { root.appendingPathComponent("conversations/\(conversation).db").path }

    private func insert(_ idx: Int, _ data: [UInt8]) -> String {
        "insert into gen_metadata (idx, data) values (\(idx), x'\(P.hex(data))');"
    }

    /// agy keeps the database in WAL mode while it works on the conversation: its newest rows are in
    /// the write-ahead log until it checkpoints, and they are the ones read.
    func testTheNewestRowIsReadFromTheWriteAheadLogOfAConversationAgyHasOpen() throws {
        let lock = try makeConversation(rows: [(idx: 1, data: row(used: 4100, window: 10_000))])
        let agy = try LiveSQLiteWriter(path: database)
        defer { agy.close() }
        try agy.run("pragma journal_mode=wal; pragma wal_autocheckpoint=0; " + insert(2, row(used: 4600, window: 10_000)))

        XCTAssertEqual(try AgySessionReader(scratch: root).read(target([lock])).contextPercent, 46)
    }

    /// A conversation agy started since its last checkpoint has even its table in the log alone.
    func testAConversationWhoseTableIsOnlyInTheWriteAheadLogIsRead() throws {
        let lock = try makeConversation(rows: [], makeDatabase: false)
        let agy = try LiveSQLiteWriter(path: database)
        defer { agy.close() }
        try agy.run("pragma journal_mode=wal; pragma wal_autocheckpoint=0; "
            + "create table gen_metadata (idx integer, data blob, size integer not null default 0, primary key (idx)); "
            + insert(1, row(used: 1, window: 4)))

        XCTAssertEqual(try AgySessionReader(scratch: root).read(target([lock])).contextPercent, 25)
    }

    /// Between turns agy closes the database and deletes its emptied `-wal` and its `-shm`, which a
    /// read-only open needs. (macOS's sqlite3 keeps both, so the made-up one has them taken away.)
    func testAConversationAgyHasClosedIsRead() throws {
        let lock = try makeConversation(rows: [(idx: 1, data: row(used: 3, window: 4))])
        try sqlite(database, "pragma journal_mode=wal;")
        for leftover in [database + "-wal", database + "-shm"] where FileManager.default.fileExists(atPath: leftover) {
            if leftover.hasSuffix("-wal") {
                let wal = try FileManager.default.attributesOfItem(atPath: leftover)
                XCTAssertEqual(wal[.size] as? Int, 0, "the close checkpointed the log")
            }
            try FileManager.default.removeItem(atPath: leftover)
        }
        XCTAssertThrowsError(try SQLiteCLI.rows(Row.self, in: database, query: "select idx from gen_metadata"))

        XCTAssertEqual(try AgySessionReader(scratch: root).read(target([lock])).contextPercent, 75)
    }

    func testAFullerThanFullWindowReadsAsFull() throws {
        let lock = try makeConversation(rows: [(idx: 1, data: row(used: 300, window: 200))])
        XCTAssertEqual(try AgySessionReader().read(target([lock])).contextPercent, 100)
    }

    // MARK: - A record that is found but cannot be read

    private func assertReadThrows(_ lock: String, containing reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AgySessionReader().read(target([lock])), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription, file: file, line: line)
        }
    }

    func testADatabaseThatIsNotOneThrows() throws {
        let lock = try makeConversation(rows: [], makeDatabase: false)
        try Data("not a database".utf8).write(to: root.appendingPathComponent("conversations/\(conversation).db"))
        assertReadThrows(lock, containing: "sqlite3 could not read")
    }

    func testADatabaseWithoutTheTableThrows() throws {
        let lock = try makeConversation(rows: [], makeDatabase: false)
        try sqlite(root.appendingPathComponent("conversations/\(conversation).db").path, "create table other (n int);")
        assertReadThrows(lock, containing: "gen_metadata")
    }

    func testARowThatIsNotProtobufThrows() throws {
        // A tag claiming field 1 holds 200 bytes, with 1 behind it.
        let lock = try makeConversation(rows: [(idx: 1, data: [0x0a, 0xc8, 0x01, 0x00])])
        assertReadThrows(lock, containing: "protobuf")
    }
}
