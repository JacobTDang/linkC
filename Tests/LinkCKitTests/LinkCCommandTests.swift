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
    /// `seen` is the request as linkC found it then: a command that gets no answer withdraws its request
    /// before it returns, so a test reads what was sent here.
    private final class World: @unchecked Sendable {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var running = true
        var launched = false
        var answer: OpenResult?
        var caller: (agent: AgentKind, sessionId: String?)?
        var seen: OpenRequest?
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
                guard let request = store.pending().first else { return }
                if world.seen == nil { world.seen = request }
                if let answer = world.answer {
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

        let sent = try XCTUnwrap(world.seen)
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

        let sent = try XCTUnwrap(world.seen)
        XCTAssertEqual(sent.task, OpenRequest.TaskOrigin(fromAgent: .claude, fromSessionId: "S7"))
    }

    func testATaskWithNoCallingAgentIsRefused() throws {
        let world = World()
        let outcome = LinkCCommand.run(try open(["codex", "--task", "carry"]), in: environment(world))

        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.output, "linkc: --task is for an agent handing off work; run without --task to open your own session.")
        XCTAssertNil(world.seen, "nothing was asked of linkC")
        XCTAssertTrue(store.pending().isEmpty)
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

    // MARK: - Arguments, edge cases

    /// Help is an option: before the prompt and before `--`. After them, `-h` is a prompt word and
    /// `--help` an unknown option, so a hand-off like "fix the -h flag" is never read as a help request.
    func testHelpIsOnlyAnOptionBeforeThePrompt() throws {
        XCTAssertEqual(try LinkCCommand.parse(["-h"]), .help)
        XCTAssertEqual(try open(["codex", "--", "-h"]).prompt, "-h")
        XCTAssertEqual(try open(["codex", "fix", "the", "-h", "flag"]).prompt, "fix the -h flag")
        XCTAssertNotNil(usageError(["codex", "fix", "--help"]), "an unknown option after the prompt")
    }

    /// A prompt of only spaces is no prompt: `--task "$UNSET"` must not hand off nothing.
    func testABlankPromptIsNoPrompt() throws {
        XCTAssertNil(try open(["codex", ""]).prompt)
        XCTAssertNil(try open(["codex", "  "]).prompt)
        XCTAssertNotNil(usageError(["codex", "--task", ""]))
        XCTAssertNotNil(usageError(["codex", "--task", "   "]))
        XCTAssertEqual(try open(["codex", "  say hi  "]).prompt, "say hi")
    }

    /// Before the agent any dash-word is an option; after it, single-dash words are prompt words.
    func testSingleDashWordsAfterTheAgentArePromptWords() throws {
        XCTAssertEqual(try open(["codex", "fix", "-1", "-v"]).prompt, "fix -1 -v")
        XCTAssertNotNil(usageError(["-v", "codex"]))
        XCTAssertNotNil(usageError(["codex", "fix", "--verbose"]))
        XCTAssertNotNil(usageError(["codex", "--tier", "--task", "x"]), "--task is not a tier")
    }

    // MARK: - Running, edge cases

    /// linkC finds the request on its first look: it is written before linkC is started.
    func testTheRequestIsWrittenBeforeLinkCIsStarted() throws {
        let world = World()
        world.running = false
        world.answer = .opened(sessionId: "S1", message: "ok")
        var env = environment(world)
        var pendingAtLaunch: [OpenRequest] = []
        env.launchLinkC = { [store] in pendingAtLaunch = store.pending() }
        _ = LinkCCommand.run(try open(["codex"]), in: env)

        XCTAssertEqual(pendingAtLaunch.count, 1)
    }

    /// A linkC that could not be started must never open the window later: the request is withdrawn.
    func testALaunchFailureWithdrawsTheRequest() throws {
        let world = World()
        world.running = false
        var env = environment(world)
        env.launchLinkC = { throw LinkCCommand.LaunchError(status: 1) }
        let outcome = LinkCCommand.run(try open(["codex"]), in: env)

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC is not running and could not be started"), outcome.output)
        XCTAssertTrue(store.pending().isEmpty)
    }

    /// A clock that never moves (a wall clock stepped back, a broken one) can't keep the command waiting
    /// forever: it gives up after as many polls as the timeout allows.
    func testAFrozenClockStillTimesOut() throws {
        let world = World()
        var env = environment(world)
        var polls = 0
        env.sleep = { _ in polls += 1 }
        let outcome = LinkCCommand.run(try open(["codex"]), in: env)

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC did not answer within 20 seconds"), outcome.output)
        XCTAssertLessThanOrEqual(polls, 201)
        XCTAssertTrue(store.pending().isEmpty)
    }

    /// A zero poll interval (a broken environment) doesn't crash the command: it reads once and gives up.
    func testAZeroPollIntervalReadsOnceAndGivesUp() throws {
        let world = World()
        var env = environment(world)
        env.pollInterval = 0
        var polls = 0
        env.sleep = { _ in polls += 1 }
        let outcome = LinkCCommand.run(try open(["codex"]), in: env)

        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC did not answer"), outcome.output)
        XCTAssertEqual(polls, 0)
    }

    /// Giving up, the command can fail both to withdraw its request and to read an answer that landed
    /// meanwhile. It says both: the request left behind may still open a window.
    func testGivingUpReportsAFailedWithdrawWithAnAnswerThatCantBeRead() throws {
        let world = World()
        var env = environment(world)
        env.pollInterval = 10
        env.sleep = { seconds in world.clock += seconds }
        let store = self.store
        let deadline = world.clock.addingTimeInterval(env.timeout)
        var planted = false
        // The command reads the clock right after its last look for an answer: the answer lands then,
        // and the folder turns read-only, so the withdraw fails.
        env.now = {
            if world.clock >= deadline, !planted, let request = store.pending().first {
                planted = true
                try? Data("not json".utf8).write(to: store.directory.appendingPathComponent("\(request.id).result.json"))
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
            }
            return world.clock
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
        let outcome = LinkCCommand.run(try open(["codex"]), in: env)

        XCTAssertTrue(planted, "the command never gave up")
        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.output.hasPrefix("linkc: linkC's answer could not be read"), outcome.output)
        XCTAssertTrue(outcome.output.contains("the request could not be withdrawn"), outcome.output)
    }
}
