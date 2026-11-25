import XCTest
@testable import LinkCKit

final class OpenCodeLiveReaderTests: XCTestCase {
    private var dir: URL!
    private var database: URL { dir.appendingPathComponent("opencode.db") }
    private var modelsFile: URL { dir.appendingPathComponent("models.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func sqlite(_ sql: String) throws {
        let made = try LiveProcessRunner.runCapturingSync(
            executable: SQLiteCLI.executable, args: [database.path, sql], cwd: nil, timeout: 5)
        XCTAssertEqual(made.status, 0, made.stderr)
    }

    /// The part of OpenCode 2.x's schema the reader touches, with the indexes it relies on.
    private func makeDatabase() throws {
        try sqlite("""
        create table session_v2 (id text primary key, model text);
        create table session_message (
          id text primary key, session_id text not null, type text not null, seq integer not null,
          time_created integer not null, time_updated integer not null, data text not null);
        create unique index session_message_session_seq_idx on session_message (session_id, seq);
        create index session_message_session_type_seq_idx on session_message (session_id, type, seq);
        """)
    }

    private func addSession(_ id: String) throws {
        try sqlite("insert into session_v2 values ('\(id)', '{}');")
    }

    private func addMessage(_ session: String, seq: Int, type: String, data: String) throws {
        let escaped = data.replacingOccurrences(of: "'", with: "''")
        try sqlite("insert into session_message values ('msg\(session)\(seq)', '\(session)', '\(type)', \(seq), \(seq), \(seq), '\(escaped)');")
    }

    private func assistant(input: Int, output: Int, reasoning: Int, read: Int, write: Int,
                           provider: String = "acme", model: String = "alpha-1") -> String {
        """
        {"model":{"id":"\(model)","providerID":"\(provider)","variant":"high"},"finish":"stop",\
        "tokens":{"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(read),"write":\(write)}}}
        """
    }

    private let erroredAssistant = """
    {"model":{"id":"alpha-1","providerID":"acme","variant":"high"},"finish":"error","error":{"message":"made up"}}
    """

    private func writeModels(context: Int?, provider: String = "acme", model: String = "alpha-1") throws {
        let limit = context.map { "{\"context\":\($0),\"output\":4096}" } ?? "{\"output\":4096}"
        let json = "{\"\(provider)\":{\"id\":\"\(provider)\",\"models\":{\"\(model)\":{\"id\":\"\(model)\",\"limit\":\(limit)}}}}"
        try json.write(to: modelsFile, atomically: true, encoding: .utf8)
    }

    private func reader() -> OpenCodeLiveReader {
        OpenCodeLiveReader(database: database, modelsFile: modelsFile)
    }

    private func target(_ id: String?) -> LiveSessionTarget {
        LiveSessionTarget(sessionId: "linkc-1", agent: .opencode, cwd: "/made/up", agentSessionId: id)
    }

    // MARK: - The context figure

    /// The context of the last request is everything it sent and got back: input, output,
    /// reasoning and both cache counts, as OpenCode's own sidebar adds them. Each field has a
    /// different size here, so leaving any one out gives a different figure.
    func testContextIsEveryTokenFieldOfTheNewestRequestOverTheModelsWindow() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 90000, output: 1, reasoning: 1, read: 1, write: 1))
        try addMessage("ses_a", seq: 2, type: "assistant", data: assistant(input: 10000, output: 2000, reasoning: 3000, read: 4000, write: 1000))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")), SessionLiveDetail(contextPercent: 20))
    }

    func testTheFigureIsRoundedToTheNearestPercent() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 25000, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 200_000)
        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 13, "12.5 rounds up")

        try addMessage("ses_a", seq: 2, type: "assistant", data: assistant(input: 24999, output: 0, reasoning: 0, read: 0, write: 0))
        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 12)
    }

    /// A turn that failed or is still running has no token counts; the figure is the last
    /// request that finished.
    func testNewestAssistantWithoutTokensIsSkipped() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 40000, output: 0, reasoning: 0, read: 0, write: 0))
        try addMessage("ses_a", seq: 2, type: "user", data: "{}")
        try addMessage("ses_a", seq: 3, type: "assistant", data: erroredAssistant)
        try addMessage("ses_a", seq: 4, type: "assistant", data: "{\"model\":{\"id\":\"alpha-1\",\"providerID\":\"acme\"},\"tokens\":null}")
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 40)
    }

    /// While a request runs, and after one is aborted, OpenCode records it with every count at 0:
    /// the figure stays the last request that counted anything, rather than going blank each time.
    func testANewestRequestThatCountsNothingYetIsSkipped() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 30000, output: 1000, reasoning: 0, read: 0, write: 0))
        try addMessage("ses_a", seq: 2, type: "user", data: "{}")
        try addMessage("ses_a", seq: 3, type: "assistant", data: assistant(input: 0, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 31)
    }

    /// The model that answered the request owns the window, not the session's current model.
    func testTheWindowIsTheModelThatAnsweredTheRequest() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant",
                       data: assistant(input: 50000, output: 0, reasoning: 0, read: 0, write: 0, provider: "other", model: "beta-2"))
        let json = """
        {"acme":{"models":{"alpha-1":{"limit":{"context":1000}}}},\
        "other":{"models":{"beta-2":{"limit":{"context":500000}},"alpha-1":{"limit":{"context":1000}}}}}
        """
        try json.write(to: modelsFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 10)
    }

    func testAnotherSessionsMessagesAreNotRead() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addSession("ses_b")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 10000, output: 0, reasoning: 0, read: 0, write: 0))
        try addMessage("ses_b", seq: 9, type: "assistant", data: assistant(input: 90000, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 10)
    }

    /// OpenCode's sidebar counts only the requests after the last finished compaction: what came
    /// before it was folded into a summary.
    func testRequestsBeforeTheLastCompletedCompactionAreNotCounted() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 90000, output: 0, reasoning: 0, read: 0, write: 0))
        try addMessage("ses_a", seq: 2, type: "compaction", data: "{\"status\":\"completed\"}")
        try writeModels(context: 100_000)
        XCTAssertEqual(try reader().read(target("ses_a")), SessionLiveDetail(), "nothing has been asked since the compaction")

        try addMessage("ses_a", seq: 3, type: "assistant", data: assistant(input: 5000, output: 0, reasoning: 0, read: 0, write: 0))
        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 5)
    }

    func testACompactionThatFailedMarksNoBoundary() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 30000, output: 0, reasoning: 0, read: 0, write: 0))
        try addMessage("ses_a", seq: 2, type: "compaction", data: "{\"status\":\"failed\"}")
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 30)
    }

    func testAnOverfullContextShowsAsFull() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 130_000, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")).contextPercent, 100)
    }

    // MARK: - No window known, nothing found

    func testNoKnownWindowGivesNoPercent() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 40000, output: 0, reasoning: 0, read: 0, write: 0))
        let detail = SessionLiveDetail()

        // models.json has never been written.
        XCTAssertEqual(try reader().read(target("ses_a")), detail)
        // The provider is not in it.
        try writeModels(context: 100_000, provider: "elsewhere")
        XCTAssertEqual(try reader().read(target("ses_a")), detail)
        // The model is not in it.
        try writeModels(context: 100_000, model: "gamma-3")
        XCTAssertEqual(try reader().read(target("ses_a")), detail)
        // The model has no context limit.
        try writeModels(context: nil)
        XCTAssertEqual(try reader().read(target("ses_a")), detail)
        // A limit of zero is no window.
        try writeModels(context: 0)
        XCTAssertEqual(try reader().read(target("ses_a")), detail)
    }

    func testARequestWithNoTokensCountedHasNoFigure() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 0, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")), SessionLiveDetail())
    }

    func testASessionWithNoAssistantMessageHasNoFigure() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "user", data: "{}")
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_a")), SessionLiveDetail())
    }

    func testAnUnknownSessionIsAnEmptyDetail() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 40000, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("ses_missing")), SessionLiveDetail())
    }

    func testASessionLinkCDoesNotKnowTheAgentIdOfIsAnEmptyDetail() throws {
        try makeDatabase()
        try writeModels(context: 100_000)
        XCTAssertEqual(try reader().read(target(nil)), SessionLiveDetail())
    }

    func testNoDatabaseYetIsAnEmptyDetail() throws {
        try writeModels(context: 100_000)
        XCTAssertEqual(try reader().read(target("ses_a")), SessionLiveDetail())
    }

    func testASessionIdWithAQuoteIsLookedUpAsText() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 40000, output: 0, reasoning: 0, read: 0, write: 0))
        try writeModels(context: 100_000)

        XCTAssertEqual(try reader().read(target("x' or '1'='1")), SessionLiveDetail())
        XCTAssertEqual(try reader().read(target("ses_a' --")), SessionLiveDetail())
    }

    /// The database, its write-ahead log and the catalog are what a read reads.
    func testTheDatabaseItsLogAndTheCatalogAreWhatAReadReads() throws {
        XCTAssertEqual(try reader().sources(of: target("ses_a")), [database.path, database.path + "-wal", modelsFile.path])
        XCTAssertEqual(try reader().sources(of: target(nil)), [])
    }

    // MARK: - Found but unreadable

    func testTokensThatAreNotCountsThrow() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant",
                       data: "{\"model\":{\"id\":\"alpha-1\",\"providerID\":\"acme\"},\"tokens\":{\"input\":\"many\",\"output\":1,\"reasoning\":1,\"cache\":{\"read\":1,\"write\":1}}}")
        try writeModels(context: 100_000)

        XCTAssertThrowsError(try reader().read(target("ses_a"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("tokens"), error.localizedDescription)
        }
    }

    /// Counts too big to add are a read failure, not a trap on the sum.
    func testTokensTooBigToAddThrow() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant",
                       data: assistant(input: Int.max, output: Int.max, reasoning: 1, read: 1, write: 1))
        try writeModels(context: 100_000)

        XCTAssertThrowsError(try reader().read(target("ses_a"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("tokens"), error.localizedDescription)
        }
    }

    func testTokensMissingAFieldThrow() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant",
                       data: "{\"model\":{\"id\":\"alpha-1\",\"providerID\":\"acme\"},\"tokens\":{\"input\":1,\"output\":1,\"reasoning\":1}}")
        try writeModels(context: 100_000)

        XCTAssertThrowsError(try reader().read(target("ses_a")))
    }

    func testADatabaseThatIsNotOneThrowsWithSQLitesReason() throws {
        try "this is not a database".write(to: database, atomically: true, encoding: .utf8)
        try writeModels(context: 100_000)

        XCTAssertThrowsError(try reader().read(target("ses_a"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a database"), error.localizedDescription)
        }
    }

    func testADatabaseWithoutTheMessageTableThrows() throws {
        try sqlite("create table unrelated (n int);")
        try writeModels(context: 100_000)

        XCTAssertThrowsError(try reader().read(target("ses_a"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("session_message"), error.localizedDescription)
        }
    }

    func testAModelsFileThatIsNotJSONThrows() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 40000, output: 0, reasoning: 0, read: 0, write: 0))
        try "not json".write(to: modelsFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try reader().read(target("ses_a"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("models.json"), error.localizedDescription)
        }
    }

    // MARK: - The models file is read again when it changes

    func testAChangedModelsFileIsReadAgain() throws {
        try makeDatabase()
        try addSession("ses_a")
        try addMessage("ses_a", seq: 1, type: "assistant", data: assistant(input: 40000, output: 0, reasoning: 0, read: 0, write: 0))
        let reader = reader()

        try writeModels(context: 100_000)
        XCTAssertEqual(try reader.read(target("ses_a")).contextPercent, 40)

        try writeModels(context: 400_000)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: modelsFile.path)
        XCTAssertEqual(try reader.read(target("ses_a")).contextPercent, 10)
    }

    // MARK: - The query stays on the indexes

    /// The real database is about a gigabyte: a query that scans it, or sorts all of it, would
    /// stall the app. Every table the query reads must be searched by an index.
    func testTheQueryReadsThroughTheIndexesOnly() throws {
        try makeDatabase()
        let plan = try LiveProcessRunner.runCapturingSync(
            executable: SQLiteCLI.executable,
            args: [database.path, "explain query plan " + OpenCodeLiveReader.lastRequestQuery(sessionId: "ses_a")],
            cwd: nil, timeout: 5)
        XCTAssertEqual(plan.status, 0, plan.stderr)
        XCTAssertTrue(plan.stdout.contains("USING INDEX session_message_session_type_seq_idx"), plan.stdout)
        XCTAssertFalse(plan.stdout.contains("SCAN"), plan.stdout)
        XCTAssertFalse(plan.stdout.contains("TEMP B-TREE"), plan.stdout)
    }
}
