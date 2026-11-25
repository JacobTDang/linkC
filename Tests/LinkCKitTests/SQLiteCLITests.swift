import XCTest
@testable import LinkCKit

final class SQLiteCLITests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A made-up database, built with the same CLI the reader uses.
    private func database(_ sql: String) throws -> String {
        let path = dir.appendingPathComponent("made up.db").path
        let made = try LiveProcessRunner.runCapturingSync(executable: SQLiteCLI.executable, args: [path, sql], cwd: nil, timeout: 5)
        XCTAssertEqual(made.status, 0, made.stderr)
        return path
    }

    private struct Row: Decodable, Equatable {
        let n: Int
        let label: String
        let blob: String
    }

    func testRowsDecodeByColumnName() throws {
        let path = try database("create table t(n int, label text, b blob); insert into t values (7, 'seven', x'0a0b');")
        let rows = try SQLiteCLI.rows(Row.self, in: path, query: "select n, label, hex(b) as blob from t")
        XCTAssertEqual(rows, [Row(n: 7, label: "seven", blob: "0A0B")])
    }

    func testNoRowsIsAnEmptyList() throws {
        let path = try database("create table t(n int, label text, b blob);")
        XCTAssertEqual(try SQLiteCLI.rows(Row.self, in: path, query: "select n, label, hex(b) as blob from t"), [])
    }

    // MARK: - Reading a clone

    private var scratch: URL { dir.appendingPathComponent("scratch") }

    private func cloneRows(_ path: String) throws -> [Row] {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return try SQLiteCLI.rows(Row.self, in: path, query: "select n, label, hex(b) as blob from t order by n", open: .clone(in: scratch))
    }

    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    private func stamp(_ path: String) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return Stamp(size: try XCTUnwrap(attributes[.size] as? Int), modified: try XCTUnwrap(attributes[.modificationDate] as? Date))
    }

    /// A writer that holds the database open keeps its newest rows in the write-ahead log until it
    /// checkpoints: the read sees them, and leaves the writer's files as they were.
    func testACloneReadSeesRowsThatAreOnlyInTheWriteAheadLog() throws {
        let path = try database("create table t(n int, label text, b blob); insert into t values (1, 'one', x'01');")
        let writer = try LiveSQLiteWriter(path: path)
        defer { writer.close() }
        try writer.run("pragma journal_mode=wal; pragma wal_autocheckpoint=0; insert into t values (2, 'two', x'02');")
        let before = try [stamp(path), stamp(path + "-wal")]

        XCTAssertEqual(try cloneRows(path).map(\.n), [1, 2])
        XCTAssertEqual(try [stamp(path), stamp(path + "-wal")], before, "the writer's own files are not touched")
    }

    /// A table the writer made since its last checkpoint is in the log alone.
    func testACloneReadSeesATableThatIsOnlyInTheWriteAheadLog() throws {
        let path = dir.appendingPathComponent("made up.db").path
        let writer = try LiveSQLiteWriter(path: path)
        defer { writer.close() }
        try writer.run("pragma journal_mode=wal; pragma wal_autocheckpoint=0; create table t(n int, label text, b blob); insert into t values (3, 'three', x'03');")

        XCTAssertEqual(try cloneRows(path).map(\.n), [3])
    }

    /// The log of a WAL database no process holds open, emptied by the last close. macOS's sqlite3
    /// keeps the empty `-wal` and its `-shm`; an agent with its own SQLite, as agy is, deletes both.
    private func closeAsAnAgentDoes(_ path: String) throws {
        XCTAssertEqual(try stamp(path + "-wal").size, 0, "the last close checkpointed the log")
        try FileManager.default.removeItem(atPath: path + "-wal")
        try FileManager.default.removeItem(atPath: path + "-shm")
    }

    /// With no `-shm` to read the log's index from, a read-only open, which cannot make one, is
    /// refused: the clone, read with a normal open, is not.
    func testACloneReadsAWALDatabaseThatNoProcessHasOpen() throws {
        let path = try database("pragma journal_mode=wal; create table t(n int, label text, b blob); insert into t values (4, 'four', x'04');")
        try closeAsAnAgentDoes(path)
        XCTAssertThrowsError(try SQLiteCLI.rows(Row.self, in: path, query: "select n, label, hex(b) as blob from t"))

        XCTAssertEqual(try cloneRows(path).map(\.n), [4])
    }

    func testTheCloneIsRemovedAfterTheReadWhetherOrNotTheQueryWorks() throws {
        let path = try database("create table t(n int, label text, b blob); insert into t values (1, 'one', x'01');")
        _ = try cloneRows(path)
        XCTAssertThrowsError(try SQLiteCLI.rows(Row.self, in: path, query: "select nope from t", open: .clone(in: scratch)))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testACloneOfADatabaseThatIsNotThereIsAnError() throws {
        XCTAssertThrowsError(try cloneRows(dir.appendingPathComponent("missing.db").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testHexFromABlobColumnDecodesToItsBytes() {
        XCTAssertEqual(SQLiteCLI.bytes(fromHex: "0A0b00ff"), Data([0x0a, 0x0b, 0x00, 0xff]))
        XCTAssertEqual(SQLiteCLI.bytes(fromHex: ""), Data())
    }

    func testHexThatIsOddOrNotHexIsNil() {
        XCTAssertNil(SQLiteCLI.bytes(fromHex: "abc"))
        XCTAssertNil(SQLiteCLI.bytes(fromHex: "zz"))
        XCTAssertNil(SQLiteCLI.bytes(fromHex: "0a 0b"))
    }

    func testAFileThatIsNotThereIsAnErrorWithSQLitesReason() {
        let path = dir.appendingPathComponent("missing.db").path
        XCTAssertThrowsError(try SQLiteCLI.rows(Row.self, in: path, query: "select 1 as n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("unable to open"), error.localizedDescription)
        }
    }

    func testAQueryThatFailsIsAnErrorWithSQLitesReason() throws {
        let path = try database("create table t(n int);")
        XCTAssertThrowsError(try SQLiteCLI.rows(Row.self, in: path, query: "select nope from t")) { error in
            XCTAssertTrue(error.localizedDescription.contains("nope"), error.localizedDescription)
        }
    }
}
