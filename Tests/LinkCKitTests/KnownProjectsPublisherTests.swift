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
