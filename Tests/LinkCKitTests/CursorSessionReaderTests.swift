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
        try? FileManager.default.removeItem(atPath: path)
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
        CursorSessionReader(transcriptRoots: [])
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

    // MARK: - Step

    private let turnEnded = #"{"type":"turn_ended","status":"success"}"#

    private func userLine() -> String {
        #"{"role":"user","message":{"content":[{"type":"text","text":"made up request"}]}}"#
    }

    private func assistantLine(_ parts: String...) -> String {
        #"{"role":"assistant","message":{"content":["# + parts.joined(separator: ",") + "]}}"
    }

    private func text() -> String { #"{"type":"text","text":"made up reply"}"# }

    private func toolUse(_ name: String, _ input: String = "{}") -> String {
        #"{"type":"tool_use","name":"\#(name)","input":\#(input)}"#
    }

    /// A made-up transcript where Cursor keeps one: `<root>/projects/<project>/agent-transcripts/<chat id>/<chat id>.jsonl`.
    private func transcript(_ lines: [String], root: String = ".cursor", chatId: String = "chat-one",
                            endingWith ending: String = "\n") throws {
        let folder = dir.appendingPathComponent("\(root)/projects/a-folder/agent-transcripts/\(chatId)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + ending).write(to: folder.appendingPathComponent("\(chatId).jsonl"), atomically: true, encoding: .utf8)
    }

    private func stepReader(tailBytes: Int = 1 << 20) -> CursorSessionReader {
        CursorSessionReader(
            transcriptRoots: [dir.appendingPathComponent(".cursor/projects"), dir.appendingPathComponent(".cursor-grok/projects")],
            tailBytes: tailBytes)
    }

    private func step(of lines: [String], endingWith ending: String = "\n", tailBytes: Int = 1 << 20) throws -> String? {
        let store = try chatStore()
        try transcript(lines, endingWith: ending)
        return try stepReader(tailBytes: tailBytes).read(target([store])).step
    }

    func testAShellCommandIsTheStepAsItsFirstLine() throws {
        let call = toolUse("Shell", #"{"command":"swift test --filter Made\nsecond line"}"#)
        XCTAssertEqual(try step(of: [userLine(), assistantLine(text(), call)]), "$ swift test --filter Made")
    }

    func testAFileToolIsTheStepByItsFileName() throws {
        let read = toolUse("Read", #"{"path":"/made/up/dir/Thing.swift"}"#)
        XCTAssertEqual(try step(of: [userLine(), assistantLine(read)]), "Read Thing.swift")
        let edit = toolUse("StrReplace", #"{"path":"/made/up/dir/Other.swift","old_string":"a","new_string":"b"}"#)
        XCTAssertEqual(try step(of: [userLine(), assistantLine(edit)]), "StrReplace Other.swift")
    }

    func testAnyOtherToolIsTheStepByItsName() throws {
        XCTAssertEqual(try step(of: [userLine(), assistantLine(toolUse("Grep", #"{"pattern":"made up"}"#))]), "Grep")
        XCTAssertEqual(try step(of: [userLine(), assistantLine(toolUse("Shell", "{}"))]), "Shell")
        XCTAssertEqual(try step(of: [userLine(), assistantLine(toolUse("Read", "{}"))]), "Read")
    }

    func testAnMCPCallIsTheStepByTheToolItCalls() throws {
        let call = toolUse("CallDynamicTool", #"{"namespace":"made-up-server","toolName":"made_up_tool","arguments":{}}"#)
        XCTAssertEqual(try step(of: [userLine(), assistantLine(call)]), "made_up_tool")
        let unnamed = toolUse("CallDynamicTool", #"{"namespace":"made-up-server"}"#)
        XCTAssertEqual(try step(of: [userLine(), assistantLine(unnamed)]), "CallDynamicTool")
    }

    func testTheLastToolOfTheLastLineIsTheStep() throws {
        let first = toolUse("Read", #"{"path":"/made/up/One.swift"}"#)
        let second = toolUse("Read", #"{"path":"/made/up/Two.swift"}"#)
        let third = toolUse("Read", #"{"path":"/made/up/Three.swift"}"#)
        let lines = [userLine(), assistantLine(first), assistantLine(text()), assistantLine(text(), second, third, text())]
        XCTAssertEqual(try step(of: lines), "Read Three.swift")
    }

    func testAToolFromBeforeTheLastUserLineIsNotTheStep() throws {
        let old = toolUse("Shell", #"{"command":"old"}"#)
        XCTAssertNil(try step(of: [userLine(), assistantLine(old), turnEnded, userLine(), assistantLine(text())]))
        XCTAssertNil(try step(of: [userLine(), assistantLine(old), userLine()]))
    }

    func testAFinishedTurnHasNoStep() throws {
        let call = toolUse("Shell", #"{"command":"swift build"}"#)
        XCTAssertNil(try step(of: [userLine(), assistantLine(call), assistantLine(text()), turnEnded]))
    }

    func testALineBeingWrittenIsSkippedForTheLastCompleteOne() throws {
        let call = toolUse("Shell", #"{"command":"swift build"}"#)
        let unfinished = String(assistantLine(toolUse("Read", #"{"path":"/made/up/Half.swift"}"#)).dropLast(9))
        XCTAssertEqual(try step(of: [userLine(), assistantLine(call), unfinished], endingWith: ""), "$ swift build")
    }

    func testACompleteLastLineWithoutANewlineCounts() throws {
        let call = toolUse("Shell", #"{"command":"swift build"}"#)
        XCTAssertEqual(try step(of: [userLine(), assistantLine(call)], endingWith: ""), "$ swift build")
    }

    func testALongCommandIsCutShort() throws {
        let long = String(repeating: "x", count: 100)
        let label = try XCTUnwrap(step(of: [userLine(), assistantLine(toolUse("Shell", #"{"command":"\#(long)"}"#))]))
        XCTAssertEqual(label, "$ " + String(repeating: "x", count: 57) + "…")
    }

    func testOnlyTheEndOfALongTranscriptIsRead() throws {
        let filler = (0..<40).map { _ in assistantLine(toolUse("Grep", #"{"pattern":"made up filler"}"#)) }
        let call = toolUse("Shell", #"{"command":"swift build"}"#)
        let lines = [userLine()] + filler + [assistantLine(call)]
        // The window starts inside a filler line, which must not be parsed.
        XCTAssertEqual(try step(of: lines, tailBytes: 400), "$ swift build")
    }

    func testAChatWithNoTranscriptYetHasContextButNoStep() throws {
        let store = try chatStore(blob: rootBlob(used: 50, window: 100))
        let detail = try stepReader().read(target([store]))
        XCTAssertEqual(detail, SessionLiveDetail(contextPercent: 50))
    }

    func testGrokTranscriptsAreFoundWhereverTheyAreKept() throws {
        let store = try chatStore(root: ".cursor-grok", blob: rootBlob(used: 50, window: 100))
        try transcript([userLine(), assistantLine(toolUse("Shell", #"{"command":"swift build"}"#))], root: ".cursor")
        let detail = try stepReader().read(target([store], agent: .grok))
        XCTAssertEqual(detail, SessionLiveDetail(contextPercent: 50, step: "$ swift build"))
    }

    // MARK: - What a read reads

    private var transcriptPath: String {
        dir.appendingPathComponent(".cursor/projects/a-folder/agent-transcripts/chat-one/chat-one.jsonl").path
    }

    /// The chat store, its write-ahead log and the transcript are what a read reads.
    func testTheStoreItsLogAndTheTranscriptAreWhatAReadReads() throws {
        let store = try chatStore()
        XCTAssertEqual(try stepReader().sources(of: target([store])), [store, store + "-wal"])

        try transcript([userLine()])
        // The roots are listed to find it, which names it as the kernel does (`/private/var/…`).
        let found = try XCTUnwrap(ProcessSnooper.canonicalPath(transcriptPath))
        XCTAssertEqual(try stepReader().sources(of: target([store])), [store, store + "-wal", found])
        XCTAssertEqual(try stepReader().sources(of: target([])), [])
    }

    /// The transcripts folder holds a folder per project, listed to find a chat's transcript; once
    /// found, it is not looked for again while it is there.
    func testAChatsTranscriptIsLookedForOnceFound() throws {
        let store = try chatStore()
        try transcript([userLine(), assistantLine(toolUse("Shell", #"{"command":"swift build"}"#))])
        let reader = stepReader()
        XCTAssertEqual(try reader.read(target([store])).step, "$ swift build")

        // Listing the folder is refused now; reaching a file through it is not.
        let projects = dir.appendingPathComponent(".cursor/projects").path
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: projects)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects) }

        XCTAssertEqual(try reader.read(target([store])).step, "$ swift build")
    }

    // MARK: - One part read, the other not

    private func assertPartial(_ store: String, keeps detail: SessionLiveDetail, sayingAll reasons: [String],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try stepReader().read(target([store])), file: file, line: line) { error in
            guard let partial = error as? PartialLiveRead else {
                return XCTFail("not a partial read: \(error)", file: file, line: line)
            }
            XCTAssertEqual(partial.detail, detail, file: file, line: line)
            for reason in reasons {
                XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription, file: file, line: line)
            }
        }
    }

    /// A transcript line that is not JSON leaves the step unread, and says so; the context, read
    /// from the chat store, still stands.
    func testATranscriptLineThatIsNotJSONLeavesTheContextStanding() throws {
        let store = try chatStore(blob: rootBlob(used: 50, window: 100))
        try transcript([userLine(), "not json", assistantLine(text())])
        assertPartial(store, keeps: SessionLiveDetail(contextPercent: 50), sayingAll: ["not JSON"])
    }

    /// A chat store that cannot be read leaves the step, read from the transcript, standing.
    func testAStoreThatCannotBeReadLeavesTheStepStanding() throws {
        let store = try chatStore()
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: store))
        try transcript([userLine(), assistantLine(toolUse("Shell", #"{"command":"swift build"}"#))])
        assertPartial(store, keeps: SessionLiveDetail(step: "$ swift build"), sayingAll: ["sqlite3 could not read"])
    }

    /// A transcripts folder that cannot be listed costs the session its step, not its context: what a
    /// read reads is still the chat store and its log, so the sampler reads it, and the part read
    /// says what could not be listed.
    func testATranscriptsFolderThatCannotBeListedLeavesTheContextStanding() async throws {
        let store = try chatStore(blob: rootBlob(used: 50, window: 100))
        try transcript([userLine()])
        let projects = dir.appendingPathComponent(".cursor/projects").path
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: projects)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects) }

        XCTAssertEqual(try stepReader().sources(of: target([store])), [store, store + "-wal"])
        assertPartial(store, keeps: SessionLiveDetail(contextPercent: 50), sayingAll: ["projects"])

        let logged = LoggedLines()
        let sampler = LiveDetailSampler(readers: [.cursor: stepReader()], log: { logged.append($0) }, openFiles: { _ in [store] })
        await sampler.refresh([LiveDetailSampler.Session(id: "S1", agent: .cursor, cwd: cwd, agentSessionId: nil, pid: 1)])?.value
        XCTAssertEqual(sampler.detail(for: "S1"), SessionLiveDetail(contextPercent: 50))
        XCTAssertEqual(logged.all.count, 1)
        XCTAssertEqual(logged.all.first?.contains("projects"), true, logged.all.first ?? "")
    }

    private final class LoggedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testBothFailingSayBoth() throws {
        let store = try chatStore()
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: store))
        try transcript([userLine(), "not json", assistantLine(text())])
        assertPartial(store, keeps: SessionLiveDetail(), sayingAll: ["sqlite3 could not read", "not JSON"])
    }
}
