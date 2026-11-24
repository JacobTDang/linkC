import XCTest
@testable import LinkCKit

final class KnownProjectsPublisherTests: XCTestCase {
    func testUnionOfSidebarMCPAndSessionsIsCanonicalSortedWithMappedActivity() throws {
        let a = "/tmp/linkc-pub-a-\(UUID().uuidString)"
        let b = "/tmp/linkc-pub-b-\(UUID().uuidString)"
        let c = "/tmp/linkc-pub-c-\(UUID().uuidString)"
        let sessions = [
            Session(id: "S2", cwd: a, title: "working", state: .working, agentKind: .codex),
            Session(id: "S1", cwd: a, title: "ready", state: .ready, agentKind: .claude),
            Session(id: "S3", cwd: b, title: "starting", state: .starting, agentKind: .claude),
            Session(id: "S4", cwd: b, title: "finished", state: .finished, agentKind: .codex),
            Session(id: "S5", cwd: b, title: "idle-wait", state: .waitingIdle, agentKind: .cursor),
        ]

        let projects = KnownProjectsPublisher.projects(
            sidebar: [b, a],
            mcpFolders: [ProjectPath.canonical(c)],
            sessions: sessions
        )

        XCTAssertEqual(projects.map(\.path), [a, b, c].map(ProjectPath.canonical).sorted())
        let projectA = try XCTUnwrap(projects.first { $0.path == ProjectPath.canonical(a) })
        XCTAssertEqual(projectA.sessions.map(\.id), ["S1", "S2"])
        XCTAssertEqual(projectA.sessions.map(\.activity), [.idle, .busy])
        XCTAssertEqual(projectA.sessions.map(\.agent), ["claude", "codex"])

        let projectB = try XCTUnwrap(projects.first { $0.path == ProjectPath.canonical(b) })
        XCTAssertEqual(projectB.sessions.map(\.id), ["S3", "S4", "S5"])
        XCTAssertEqual(projectB.sessions.map(\.activity), [.starting, .idle, .idle])

        let projectC = try XCTUnwrap(projects.first { $0.path == ProjectPath.canonical(c) })
        XCTAssertTrue(projectC.sessions.isEmpty)
    }

    /// What a panel beside a session needs to show the other sessions: title, state, since when,
    /// model, whether linkC started it for a task, and the action its row reads.
    func testEachSessionCarriesWhatItsRowShows() throws {
        let path = "/tmp/linkc-pub-detail-\(UUID().uuidString)"
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let sessions = [
            Session(id: "A", cwd: path, title: "Fix glyphs", state: .working, stateChangedAt: since,
                    agentKind: .claude, model: "claude-opus-5-5"),
            Session(id: "B", cwd: path, title: "OpenCode default", state: .waitingPermission, stateChangedAt: since,
                    agentKind: .codex, isWorker: true),
            Session(id: "C", cwd: path, title: "Idle one", state: .finished, stateChangedAt: since, agentKind: .agy),
        ]

        let projects = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions,
                                                       action: { "  \($0.title) step  " })

        let open = try XCTUnwrap(projects.first).sessions
        XCTAssertEqual(open.map(\.title), ["Fix glyphs", "OpenCode default", "Idle one"])
        XCTAssertEqual(open.map(\.state), ["working", "waitingPermission", "finished"])
        XCTAssertEqual(open.map(\.since), Array(repeating: "2026-09-21T14:13:20Z", count: 3))
        XCTAssertEqual(open.map(\.model), ["claude-opus-5-5", nil, nil])
        XCTAssertEqual(open.map(\.worker), [false, true, false])
        XCTAssertEqual(open.map(\.action), ["Fix glyphs step", "OpenCode default step", nil])
    }

    /// Reading an action reads the session's terminal: one whose state shows none is never asked.
    func testOnlyAWorkingOrPermissionWaitingSessionIsAskedForItsAction() {
        let path = "/tmp/linkc-pub-ask-\(UUID().uuidString)"
        let sessions = SessionState.allCases.filter { $0 != .ended }.map {
            Session(id: $0.rawValue, cwd: path, title: $0.rawValue, state: $0)
        }
        var asked: [String] = []
        _ = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions,
                                           action: { asked.append($0.id); return nil })
        XCTAssertEqual(asked.sorted(), ["waitingPermission", "working"])
    }

    /// A session whose own turn ended can still be running subagents: its row says how many.
    func testEachSessionCarriesItsRunningSubagentCount() throws {
        let path = "/tmp/linkc-pub-subagents-\(UUID().uuidString)"
        let sessions = [
            Session(id: "BUSY", cwd: path, title: "fan-out", state: .finished),
            Session(id: "CALM", cwd: path, title: "quiet", state: .finished),
        ]

        let projects = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions,
                                                       subagents: { $0.id == "BUSY" ? 3 : 0 })

        let open = try XCTUnwrap(projects.first).sessions
        XCTAssertEqual(open.map(\.subagents), [3, nil], "none running leaves the field out")
    }

    /// The model a session runs now, where its agent reports one, wins over the one it launched on.
    func testTheLiveModelWinsOverTheLaunchModel() throws {
        let path = "/tmp/linkc-pub-model-\(UUID().uuidString)"
        let sessions = [
            Session(id: "LIVE", cwd: path, title: "switched", state: .ready, agentKind: .claude, model: "claude-sonnet-5-5"),
            Session(id: "LAUNCH", cwd: path, title: "pinned", state: .ready, agentKind: .agy, model: "gemini-3.8-flash-medium"),
        ]

        let projects = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions,
                                                       liveModel: { $0.id == "LIVE" ? "Opus 5.5" : nil })

        // Sessions are listed by id: LAUNCH, then LIVE.
        XCTAssertEqual(try XCTUnwrap(projects.first).sessions.map(\.model), ["gemini-3.8-flash-medium", "Opus 5.5"])
    }

    /// A session's own `title` is its folder's name; its row reads the conversation's title, a held
    /// task's, or the agent's numbered name. The row's wins, so two sessions in one folder differ.
    func testTheRowsTitleWinsOverTheFolderName() throws {
        let path = "/tmp/linkc-pub-title-\(UUID().uuidString)"
        let sessions = [
            Session(id: "A", cwd: path, title: "linkC", state: .ready, agentKind: .claude),
            Session(id: "B", cwd: path, title: "linkC", state: .ready, agentKind: .claude),
        ]

        let projects = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions,
                                                       title: { ["A": "Fix the glyphs", "B": "Claude 2"][$0.id] })

        XCTAssertEqual(try XCTUnwrap(projects.first).sessions.map(\.title), ["Fix the glyphs", "Claude 2"])
    }

    func testEachSessionCarriesWhenItsPromptCacheGoesCold() throws {
        let path = "/tmp/linkc-pub-cache-\(UUID().uuidString)"
        let sessions = [
            Session(id: "A", cwd: path, title: "exact", state: .finished, agentKind: .claude),
            Session(id: "B", cwd: path, title: "guessed", state: .finished, agentKind: .codex),
            Session(id: "C", cwd: path, title: "unknown", state: .finished, agentKind: .agy),
        ]
        let at = Date(timeIntervalSince1970: 1_790_003_600)

        let projects = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions, cache: {
            switch $0.id {
            case "A": CacheExpiry(at: at, isEstimate: false)
            case "B": CacheExpiry(at: at, isEstimate: true)
            default: nil
            }
        })

        let open = try XCTUnwrap(projects.first).sessions
        XCTAssertEqual(open.map(\.cacheExpiresAt), ["2026-09-21T15:13:20Z", "2026-09-21T15:13:20Z", nil])
        XCTAssertEqual(open.map(\.cacheEstimate), [nil, true, nil], "an exact expiry leaves the flag out")
    }

    func testEndedSessionIsLeftOut() {
        let path = "/tmp/linkc-pub-ended-\(UUID().uuidString)"
        let sessions = [
            Session(id: "live", cwd: path, title: "live", state: .ready, agentKind: .claude),
            Session(id: "gone", cwd: path, title: "gone", state: .ended, agentKind: .codex),
        ]
        let projects = KnownProjectsPublisher.projects(sidebar: [path], mcpFolders: [], sessions: sessions)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].sessions.map(\.id), ["live"])
    }

    func testSidebarPathThatIsAlsoAnMCPFolderAppearsOnce() {
        let path = "/tmp/linkc-pub-dup-\(UUID().uuidString)"
        let canonical = ProjectPath.canonical(path)
        let projects = KnownProjectsPublisher.projects(
            sidebar: [path],
            mcpFolders: [canonical],
            sessions: []
        )
        XCTAssertEqual(projects.map(\.path), [canonical])
    }

    func testPathsAreTheSameUnionAsProjectsWithoutTheSessions() {
        let a = "/tmp/linkc-pub-paths-a-\(UUID().uuidString)"
        let b = "/tmp/linkc-pub-paths-b-\(UUID().uuidString)"
        let c = "/tmp/linkc-pub-paths-c-\(UUID().uuidString)"
        let sessions = [
            Session(id: "S1", cwd: a, title: "live", state: .working, agentKind: .claude),
            Session(id: "S2", cwd: c, title: "gone", state: .ended, agentKind: .codex),
        ]

        let paths = KnownProjectsPublisher.paths(sidebar: [b], mcpFolders: [], sessions: sessions)
        let projects = KnownProjectsPublisher.projects(sidebar: [b], mcpFolders: [], sessions: sessions)

        XCTAssertEqual(paths, Set([a, b].map(ProjectPath.canonical)), "an ended session's folder is not a project")
        XCTAssertEqual(paths, Set(projects.map(\.path)))
    }
}
