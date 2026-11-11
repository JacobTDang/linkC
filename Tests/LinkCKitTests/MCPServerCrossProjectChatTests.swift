import XCTest
@testable import LinkCKit

/// Cross-project `linkc_send_message(project:)` / `reply_to` (spec 2026-11-11 cross-project §6).
final class MCPServerCrossProjectChatTests: XCTestCase {
    private var tempDir: URL!
    private var home: URL!
    private var away: URL!
    private var file: KnownProjectsFile!
    private var homeInbox: InboxStore!
    private var awayInbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-xproj-chat-\(UUID().uuidString)")
        home = tempDir.appendingPathComponent("money-printer")
        away = tempDir.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        file = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
        homeInbox = InboxStore(workspaceRoot: home.path)
        awayInbox = InboxStore(workspaceRoot: away.path)
        try writeProjects(awaySessions: [
            .init(id: "away-codex", agent: "codex", activity: .idle)
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func writeProjects(awaySessions: [KnownProject.OpenSession], extra: [KnownProject] = []) throws {
        try file.write([
            KnownProject(path: ProjectPath.canonical(home.path), sessions: [
                .init(id: "home-claude", agent: "claude", activity: .idle)
            ]),
            KnownProject(path: ProjectPath.canonical(away.path), sessions: awaySessions)
        ] + extra)
    }

    /// A folder named `name` under its own parent, so it can share a name with another known folder.
    private func makeFolder(named name: String, under parent: String) throws -> URL {
        let folder = tempDir.appendingPathComponent(parent).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A message in away's inbox that came from `home`, as a cross-project send leaves it.
    private func messageFromHome(
        fromSessionId: String? = "home-claude",
        chainDepth: Int = 0,
        body: String = "status?"
    ) throws -> PendingMessage {
        try awayInbox.enqueue(
            from: .claude, to: .codex, kind: .peerNote, body: body,
            fromProject: ProjectPath.canonical(home.path), fromSessionId: fromSessionId, chainDepth: chainDepth
        )
    }

    private static let sizeRefusal =
        "Messages to another project are at most 2,000 characters. Point to a file path instead; both projects are on this Mac."

    private func homeServer(session: String? = "home-claude") -> MCPServer {
        var env = ["LINKC_AGENT": "claude"]
        if let session { env["LINKC_SESSION"] = session }
        return MCPServer(workspaceRoot: home.path, inboxStore: homeInbox, environment: env,
                         ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                         sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file)
    }

    private func awayServer(session: String? = "away-codex") -> MCPServer {
        var env = ["LINKC_AGENT": "codex"]
        if let session { env["LINKC_SESSION"] = session }
        return MCPServer(workspaceRoot: away.path, inboxStore: awayInbox, environment: env,
                         ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                         sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file)
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    // MARK: - Model and store

    func testOldMessageWithoutCrossProjectKeysDecodesWithChainDepthZero() throws {
        let json = #"{"id":"M1","fromAgent":"claude","toAgent":"codex","prompt":"hi","status":"queued","createdAt":0}"#
        let message = try JSONDecoder().decode(PendingMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.fromProject)
        XCTAssertNil(message.fromSessionId)
        XCTAssertEqual(message.chainDepth, 0)
    }

    func testEnqueueCrossProjectPeerNoteStoresOriginAndReplyLine() throws {
        let homePath = ProjectPath.canonical(home.path)
        let first = try awayInbox.enqueue(
            from: .claude, to: .codex, kind: .peerNote, body: "how is the ledger?",
            fromProject: homePath, fromSessionId: "home-claude", chainDepth: 0
        )
        XCTAssertEqual(first.fromProject, homePath)
        XCTAssertEqual(first.fromSessionId, "home-claude")
        XCTAssertEqual(first.chainDepth, 0)
        XCTAssertTrue(first.prompt.hasPrefix("[Peer Note from Claude Code · money-printer]: how is the ledger?"), first.prompt)
        XCTAssertTrue(
            first.prompt.contains("\nReply with linkc_send_message(project: \"money-printer\", reply_to: \"\(first.id.prefix(8))\")"),
            first.prompt
        )

        let second = try awayInbox.enqueue(
            from: .claude, to: .codex, kind: .peerNote, body: "how is the ledger?",
            fromProject: homePath, fromSessionId: "home-claude", chainDepth: 0
        )
        XCTAssertEqual(second.id, first.id, "identical cross-project bodies dedupe on the hash without the reply line")
        XCTAssertEqual(try awayInbox.fetchPending().count, 1)
    }

    func testSameTextFromTwoSessionsOfOneProjectIsNotMerged() throws {
        let first = try messageFromHome(fromSessionId: "home-claude-1")
        let second = try messageFromHome(fromSessionId: "home-claude-2")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.fromSessionId, "home-claude-2")
        XCTAssertEqual(try awayInbox.fetchPending().count, 2)
    }

    func testSameTextFromTwoFoldersWithOneNameIsNotMerged() throws {
        let first = try awayInbox.enqueue(
            from: .claude, to: .codex, kind: .peerNote, body: "status?",
            fromProject: "/x/app", fromSessionId: "s", chainDepth: 0
        )
        let second = try awayInbox.enqueue(
            from: .claude, to: .codex, kind: .peerNote, body: "status?",
            fromProject: "/y/app", fromSessionId: "s", chainDepth: 0
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.fromProject, "/y/app")
        XCTAssertEqual(try awayInbox.fetchPending().count, 2)
    }

    func testSameTextAtAnotherChainDepthIsNotMerged() throws {
        let first = try messageFromHome(chainDepth: 1)
        let second = try messageFromHome(chainDepth: 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.chainDepth, 2)
        XCTAssertEqual(try awayInbox.fetchPending().count, 2)
    }

    func testIdenticalLocalMessagesStillDedupe() throws {
        let first = try awayInbox.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "same")
        let second = try awayInbox.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "same")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try awayInbox.fetchPending().count, 1)
    }

    func testMessageMatchingHandlesShortIdAndAmbiguousPrefix() throws {
        let a = try homeInbox.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "one")
        _ = try homeInbox.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "two")
        let found = try XCTUnwrap(homeInbox.message(matching: String(a.id.prefix(8))))
        XCTAssertEqual(found.id, a.id)
        XCTAssertNil(try homeInbox.message(matching: String(a.id.prefix(4))))

        // Force two messages whose ids share an 8-char prefix by writing the inbox directly.
        var inbox = try homeInbox.load()
        let shared = String(UUID().uuidString.prefix(8)).lowercased()
        let firstId = shared + "-1111-4111-8111-111111111111"
        let secondId = shared + "-2222-4222-8222-222222222222"
        inbox.messages = [
            PendingMessage(id: firstId, fromAgent: .codex, toAgent: .claude, prompt: "a", kind: .peerNote),
            PendingMessage(id: secondId, fromAgent: .codex, toAgent: .claude, prompt: "b", kind: .peerNote)
        ]
        try homeInbox.saveRaw(inbox)
        XCTAssertThrowsError(try homeInbox.message(matching: shared)) { error in
            guard case InboxError.ambiguousMessageId = error else {
                return XCTFail("expected ambiguousMessageId, got \(error)")
            }
        }
    }

    // MARK: - linkc_send_message(project:)

    func testSendMessageToAnotherProjectEnqueuesWithReturnAddress() throws {
        let result = try call(homeServer(), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "how's the ledger?"
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
        let message = try XCTUnwrap(awayInbox.fetchPending().first)
        XCTAssertEqual(message.fromAgent, .claude)
        XCTAssertEqual(message.toAgent, .codex)
        XCTAssertEqual(message.fromProject, ProjectPath.canonical(home.path))
        XCTAssertEqual(message.fromSessionId, "home-claude")
        XCTAssertEqual(message.chainDepth, 0)
        XCTAssertTrue(message.prompt.contains("how's the ledger?"), message.prompt)
        XCTAssertTrue(message.prompt.contains("money-printer"), message.prompt)
    }

    func testTwoSessionsOfOneProjectSendingTheSameTextEachKeepTheirReturnAddress() throws {
        let first = try call(homeServer(session: "home-claude-1"), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "status?"
        ])
        let second = try call(homeServer(session: "home-claude-2"), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "status?"
        ])
        XCTAssertFalse(first.isError, first.text)
        XCTAssertFalse(second.isError, second.text)
        let messages = try awayInbox.fetchPending()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(Set(messages.compactMap(\.fromSessionId)), ["home-claude-1", "home-claude-2"])
    }

    func testAMessageOverTheCrossProjectLimitIsRefusedBeforeWriting() throws {
        let long = String(repeating: "x", count: PendingMessage.crossProjectMessageLimit + 1)
        let result = try call(homeServer(), "linkc_send_message", [
            "project": "away", "to": "codex", "message": long
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, Self.sizeRefusal)
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testTheSizeCheckComesBeforeAnUnknownProject() throws {
        let long = String(repeating: "x", count: PendingMessage.crossProjectMessageLimit + 1)
        let result = try call(homeServer(), "linkc_send_message", [
            "project": "ghost", "to": "codex", "message": long
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, Self.sizeRefusal)
    }

    func testTheSizeCapAppliesToAReply() throws {
        let original = try messageFromHome()
        let long = String(repeating: "x", count: PendingMessage.crossProjectMessageLimit + 1)
        let result = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": long
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, Self.sizeRefusal)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testALocalMessageOverTwoThousandCharactersIsStillAccepted() throws {
        let long = String(repeating: "x", count: PendingMessage.crossProjectMessageLimit + 1)
        let result = try call(homeServer(), "linkc_send_message", ["to": "codex", "message": long])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try homeInbox.fetchPending().count, 1)
    }

    func testUnknownProjectIsRefusedWithTheKnownNames() throws {
        let result = try call(homeServer(), "linkc_send_message", [
            "project": "ghost", "to": "codex", "message": "ping"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, ProjectRefError.unknown("ghost", known: ["away"]).errorDescription)
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)
    }

    func testMissingProjectsFileIsRefusedOnASend() throws {
        try file.remove()
        let result = try call(homeServer(), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "ping"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, KnownProjectsError.linkCNotRunning.errorDescription)
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)
    }

    func testAProjectSendWithoutToIsRefused() throws {
        let result = try call(homeServer(), "linkc_send_message", ["project": "away", "message": "ping"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Error: Missing required argument 'to'.")
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)
    }

    func testTaskIdWithProjectOrReplyToIsRefused() throws {
        let original = try messageFromHome()
        let refusal = "task_id cannot be combined with project or reply_to."

        let withProject = try call(homeServer(), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "ping", "task_id": "abcd1234"
        ])
        XCTAssertTrue(withProject.isError)
        XCTAssertEqual(withProject.text, refusal)

        let withReplyTo = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": "pong", "task_id": "abcd1234"
        ])
        XCTAssertTrue(withReplyTo.isError)
        XCTAssertEqual(withReplyTo.text, refusal)

        XCTAssertEqual(try awayInbox.fetchPending().count, 1, "only the planted message")
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testANonStringReplyToIsRefused() throws {
        let result = try call(awayServer(), "linkc_send_message", ["reply_to": 5, "message": "pong"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "reply_to must be a message id")
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testNoOpenSessionInTheTargetProjectIsRefused() throws {
        try writeProjects(awaySessions: [])
        let result = try call(homeServer(), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "ping"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.text,
            "No Codex session is open in away. Use linkc_ask or linkc_delegate_task, which start one."
        )
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)
    }

    // MARK: - reply_to

    func testReplyToSendsHomeToTheOriginalSession() throws {
        let outbound = try call(homeServer(), "linkc_send_message", [
            "project": "away", "to": "codex", "message": "status?"
        ])
        XCTAssertFalse(outbound.isError, outbound.text)
        let original = try XCTUnwrap(awayInbox.fetchPending().first)

        let reply = try call(awayServer(), "linkc_send_message", [
            "reply_to": String(original.id.prefix(8)), "message": "ledger is green"
        ])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(try awayInbox.fetchPending().count, 1, "reply must not land in away")
        let homeMsg = try XCTUnwrap(homeInbox.fetchPending().first)
        XCTAssertEqual(homeMsg.toSessionId, "home-claude")
        XCTAssertEqual(homeMsg.toAgent, .claude)
        XCTAssertEqual(homeMsg.fromAgent, .codex)
        XCTAssertEqual(homeMsg.fromProject, ProjectPath.canonical(away.path))
        XCTAssertEqual(homeMsg.fromSessionId, "away-codex")
        XCTAssertEqual(homeMsg.chainDepth, 1)
        XCTAssertTrue(homeMsg.prompt.contains("ledger is green"), homeMsg.prompt)
    }

    func testReplyToRejectsMismatchedProjectOrTo() throws {
        let other = try makeFolder(named: "other", under: "elsewhere")
        try writeProjects(
            awaySessions: [.init(id: "away-codex", agent: "codex", activity: .idle)],
            extra: [KnownProject(path: ProjectPath.canonical(other.path), sessions: [])]
        )
        let original = try messageFromHome()
        let short = String(original.id.prefix(8))
        let projectRefusal = "project must match the message's origin (money-printer), or be omitted."

        let otherKnown = try call(awayServer(), "linkc_send_message", [
            "reply_to": short, "project": "other", "message": "nope"
        ])
        XCTAssertTrue(otherKnown.isError)
        XCTAssertEqual(otherKnown.text, projectRefusal)

        let ghost = try call(awayServer(), "linkc_send_message", [
            "reply_to": short, "project": "ghost", "message": "nope"
        ])
        XCTAssertTrue(ghost.isError)
        XCTAssertEqual(ghost.text, projectRefusal)

        let badTo = try call(awayServer(), "linkc_send_message", [
            "reply_to": short, "to": "cursor", "message": "nope"
        ])
        XCTAssertTrue(badTo.isError)
        XCTAssertEqual(badTo.text, "to must be claude (the message's sender), or be omitted.")
        XCTAssertEqual(try homeInbox.fetchPending().count, 0)
    }

    func testReplyAcceptsAProjectEqualToTheOrigin() throws {
        let original = try messageFromHome()
        let homePath = ProjectPath.canonical(home.path)
        for ref in ["money-printer", "MONEY-PRINTER", homePath] {
            let result = try call(awayServer(), "linkc_send_message", [
                "reply_to": original.id, "project": ref, "to": "claude", "message": "ok \(ref)"
            ])
            XCTAssertFalse(result.isError, "\(ref): \(result.text)")
        }
        XCTAssertEqual(try homeInbox.fetchPending().count, 3)
    }

    func testReplyWithAProjectNameAnotherKnownFolderSharesStillReachesTheOrigin() throws {
        let twin = try makeFolder(named: "money-printer", under: "elsewhere")
        let twinInbox = InboxStore(workspaceRoot: twin.path)
        try writeProjects(
            awaySessions: [.init(id: "away-codex", agent: "codex", activity: .idle)],
            extra: [KnownProject(path: ProjectPath.canonical(twin.path), sessions: [
                .init(id: "twin-claude", agent: "claude", activity: .idle)
            ])]
        )
        let original = try messageFromHome()

        let result = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "project": "money-printer", "message": "ledger is green"
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try homeInbox.fetchPending().count, 1)
        XCTAssertTrue(try twinInbox.fetchPending().isEmpty)
    }

    func testReplyIsRefusedWhenProjectsFileIsMissing() throws {
        let original = try messageFromHome()
        try file.remove()
        let result = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": "ledger is green"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, KnownProjectsError.linkCNotRunning.errorDescription)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testReplyIsRefusedWhenProjectsFileIsUnreadable() throws {
        let original = try messageFromHome()
        try Data("not json".utf8).write(to: file.url)
        let result = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": "ledger is green"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("project list at \(file.url.path) could not be read"), result.text)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testReplyIsRefusedWhenTheOriginProjectIsNoLongerKnown() throws {
        let withSession = try messageFromHome(fromSessionId: "home-claude")
        let withoutSession = try messageFromHome(fromSessionId: nil, body: "from outside")
        try file.write([
            KnownProject(path: ProjectPath.canonical(away.path), sessions: [
                .init(id: "away-codex", agent: "codex", activity: .idle)
            ])
        ])
        for original in [withSession, withoutSession] {
            let result = try call(awayServer(), "linkc_send_message", [
                "reply_to": original.id, "message": "ledger is green"
            ])
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.text, "money-printer is no longer known to linkC; the reply was not sent.")
        }
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testReplyToAMessageAtChainDepthEightIsAllowedAndGetsDepthNine() throws {
        let original = try messageFromHome(chainDepth: 8)
        let result = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": "one more"
        ])
        XCTAssertFalse(result.isError, result.text)
        let reply = try XCTUnwrap(homeInbox.fetchPending().first)
        XCTAssertEqual(reply.chainDepth, 9)
    }

    func testReplyToWithoutFromSessionIdOmitsToSessionIdAndChecksOpenSession() throws {
        let homePath = ProjectPath.canonical(home.path)
        let original = try awayInbox.enqueue(
            from: .claude, to: .codex, kind: .peerNote, body: "from outside",
            fromProject: homePath, fromSessionId: nil, chainDepth: 0
        )

        try writeProjects(awaySessions: [
            .init(id: "away-codex", agent: "codex", activity: .idle)
        ])
        // home still has a live claude session from setUp — reply should succeed with nil toSessionId
        let ok = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": "got it"
        ])
        XCTAssertFalse(ok.isError, ok.text)
        let homeMsg = try XCTUnwrap(homeInbox.fetchPending().first)
        XCTAssertNil(homeMsg.toSessionId)

        // Clear home's open claude session: open-session check must refuse.
        try file.write([
            KnownProject(path: ProjectPath.canonical(home.path), sessions: []),
            KnownProject(path: ProjectPath.canonical(away.path), sessions: [
                .init(id: "away-codex", agent: "codex", activity: .idle)
            ])
        ])
        _ = try homeInbox.markMessageDelivered(id: homeMsg.id)
        let refused = try call(awayServer(), "linkc_send_message", [
            "reply_to": original.id, "message": "again"
        ])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("No Claude"), refused.text)
    }

    func testReplyToAtChainDepthNineIsRefused() throws {
        let homePath = ProjectPath.canonical(home.path)
        let deep = PendingMessage(
            fromAgent: .claude, toAgent: .codex, prompt: "deep", kind: .peerNote,
            fromProject: homePath, fromSessionId: "home-claude", chainDepth: 9
        )
        var inbox = try awayInbox.load()
        inbox.messages.append(deep)
        try awayInbox.saveRaw(inbox)

        let result = try call(awayServer(), "linkc_send_message", [
            "reply_to": deep.id, "message": "one more"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.text,
            "This conversation has gone back and forth 10 times. Ask the user before continuing."
        )
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testReplyToUnknownIdAndLocalMessageAreRefused() throws {
        let unknown = try call(awayServer(), "linkc_send_message", [
            "reply_to": "deadbeef", "message": "hi"
        ])
        XCTAssertTrue(unknown.isError)
        XCTAssertEqual(unknown.text, "Message deadbeef not found; send without reply_to.")

        let local = try awayInbox.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "local")
        let noOrigin = try call(awayServer(), "linkc_send_message", [
            "reply_to": local.id, "message": "hi"
        ])
        XCTAssertTrue(noOrigin.isError)
        XCTAssertEqual(
            noOrigin.text,
            "Message \(local.id) did not come from another project; reply without reply_to."
        )
    }

    func testWithoutProjectAndReplyToBehaviourIsUnchanged() throws {
        let result = try call(homeServer(), "linkc_send_message", [
            "to": "codex", "message": "local hello"
        ])
        XCTAssertFalse(result.isError, result.text)
        let message = try XCTUnwrap(homeInbox.fetchPending().first)
        XCTAssertNil(message.fromProject)
        XCTAssertEqual(message.chainDepth, 0)
        XCTAssertEqual(message.prompt, "[Peer Note from Claude Code]: local hello")
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)
    }
}
