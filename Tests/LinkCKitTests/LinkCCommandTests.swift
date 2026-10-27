import XCTest
@testable import LinkCKit

final class LinkCCommandTests: XCTestCase {
    // MARK: - Arguments

    private func open(_ arguments: [String]) throws -> LinkCCommand.Invocation {
        guard case .open(let invocation) = try LinkCCommand.parse(arguments) else {
            throw XCTSkip("not an open invocation")
        }
        return invocation
    }

    private func usageError(_ arguments: [String]) -> String? {
        do {
            _ = try LinkCCommand.parse(arguments)
            return nil
        } catch let error as LinkCCommand.UsageError {
            return error.description
        } catch {
            return "unexpected \(error)"
        }
    }

    func testEveryAgentCanBeOpened() throws {
        for agent in [AgentKind.claude, .codex, .agy, .cursor, .grok] {
            XCTAssertEqual(try open([agent.rawValue]).agent, agent)
        }
    }

    func testThePromptIsTheRemainingWordsJoined() throws {
        XCTAssertEqual(try open(["codex", "fix", "the", "test"]).prompt, "fix the test")
        XCTAssertEqual(try open(["codex", "fix the test"]).prompt, "fix the test")
        XCTAssertNil(try open(["codex"]).prompt)
    }

    func testTierAndTaskAreRead() throws {
        let invocation = try open(["codex", "--tier", "deep", "--task", "hand", "off"])
        XCTAssertEqual(invocation.tier, .deep)
        XCTAssertTrue(invocation.task)
        XCTAssertEqual(invocation.prompt, "hand off")
        XCTAssertNil(try open(["codex"]).tier)
        XCTAssertFalse(try open(["codex"]).task)
    }

    func testADoubleDashMakesTheRestPromptWords() throws {
        XCTAssertEqual(try open(["codex", "--", "--task", "is", "text"]).prompt, "--task is text")
    }

    func testHelp() throws {
        XCTAssertEqual(try LinkCCommand.parse(["--help"]), .help)
        XCTAssertEqual(try LinkCCommand.parse(["codex", "-h"]), .help)
    }

    func testUsageErrors() {
        XCTAssertNotNil(usageError([]), "no agent")
        XCTAssertNotNil(usageError(["gpt"]), "unknown agent")
        XCTAssertNotNil(usageError(["shell"]), "a shell is not an agent")
        XCTAssertNotNil(usageError(["codex", "--fast"]), "unknown option")
        XCTAssertNotNil(usageError(["codex", "--tier"]), "a tier needs a value")
        XCTAssertNotNil(usageError(["codex", "--tier", "max"]), "unknown tier")
        XCTAssertNotNil(usageError(["codex", "--task"]), "a task needs a prompt")
    }

    // MARK: - Running

    private var root: URL!
    private var store: OpenRequestStore { OpenRequestStore(directory: root.appendingPathComponent("open-requests")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The outside world, with a fake linkC that answers (or not) the first time the command waits.
    private final class World: @unchecked Sendable {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var running = true
        var launched = false
        var answer: OpenResult?
        var caller: (agent: AgentKind, sessionId: String?)?
    }

    private func environment(_ world: World) -> LinkCCommand.Environment {
        let store = self.store
        return LinkCCommand.Environment(
            store: store,
            folder: root.path,
            caller: { world.caller },
            isLinkCRunning: { world.running },
            launchLinkC: { world.launched = true },
            now: { world.clock },
            sleep: { seconds in
                world.clock += seconds
                if let answer = world.answer, let request = store.pending().first {
                    try? store.answer(request.id, with: answer)
                }
            }
        )
    }

    func testAnOpenedSessionPrintsLinkCsMessageAndCleansUp() throws {
        let world = World()
        world.answer = .opened(sessionId: "S1", message: "Opened Codex in a linkC window (p).")
        let outcome = LinkCCommand.run(try open(["codex", "say", "hi"]), in: environment(world))

        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.output, "Opened Codex in a linkC window (p).")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [], "the answer is removed")
    }

    func testTheRequestCarriesTheAgentFolderPromptAndTier() throws {
        let world = World()
        _ = LinkCCommand.run(try open(["agy", "--tier", "light", "say", "hi"]), in: environment(world))

        let sent = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(sent.agent, .agy)
        XCTAssertEqual(sent.folder, ProjectPath.canonical(root.path))
        XCTAssertEqual(sent.prompt, "say hi")
        XCTAssertEqual(sent.tier, .light)
        XCTAssertNil(sent.task)
    }

    func testARefusalIsPrintedAsAnError() throws {
        let world = World()
        world.answer = .refused("no model configured for codex tier deep")
        let outcome = LinkCCommand.run(try open(["codex", "--tier", "deep"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.output, "linkc: no model configured for codex tier deep")
    }

    /// No answer within 20 seconds: the command says so and withdraws its request, so linkC never opens
    /// a window long after the user gave up.
    func testNoAnswerTimesOutAndWithdrawsTheRequest() throws {
        let world = World()
        let outcome = LinkCCommand.run(try open(["codex"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC did not answer within 20 seconds"), outcome.output)
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testLinkCIsStartedOnlyWhenItIsNotRunning() throws {
        let stopped = World()
        stopped.running = false
        stopped.answer = .opened(sessionId: "S1", message: "ok")
        _ = LinkCCommand.run(try open(["codex"]), in: environment(stopped))
        XCTAssertTrue(stopped.launched)

        let running = World()
        running.answer = .opened(sessionId: "S1", message: "ok")
        _ = LinkCCommand.run(try open(["codex"]), in: environment(running))
        XCTAssertFalse(running.launched)
    }

    func testATaskCarriesTheCallingAgent() throws {
        let world = World()
        world.caller = (.claude, "S7")
        _ = LinkCCommand.run(try open(["codex", "--task", "carry", "this"]), in: environment(world))

        let sent = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(sent.task, OpenRequest.TaskOrigin(fromAgent: .claude, fromSessionId: "S7"))
    }

    func testATaskWithNoCallingAgentIsRefused() throws {
        let world = World()
        let outcome = LinkCCommand.run(try open(["codex", "--task", "carry"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.output, "linkc: --task is for an agent handing off work; run without --task to open your own session.")
        XCTAssertTrue(store.pending().isEmpty, "nothing was asked of linkC")
    }

    func testAnAnswerThatCantBeReadIsAnError() throws {
        let world = World()
        let env = environment(world)
        var broken = env
        broken.sleep = { [store] seconds in
            world.clock += seconds
            if let request = store.pending().first {
                try? Data("not json".utf8).write(to: store.directory.appendingPathComponent("\(request.id).result.json"))
            }
        }
        let outcome = LinkCCommand.run(try open(["codex"]), in: broken)

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC's answer could not be read"), outcome.output)
    }
}
