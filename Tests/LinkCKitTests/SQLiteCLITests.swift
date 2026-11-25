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

    /// An immutable open reads a file another process may hold, without touching it.
    func testAnImmutableOpenReadsTheFileToo() throws {
        let path = try database("create table t(n int, label text, b blob); insert into t values (1, 'one', x'00');")
        let rows = try SQLiteCLI.rows(Row.self, in: path, query: "select n, label, hex(b) as blob from t", open: .immutable)
        XCTAssertEqual(rows.map(\.n), [1])
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
