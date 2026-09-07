import XCTest
@testable import LinkCKit

final class ProjectGroupTests: XCTestCase {
    func testEmptySessionsReturnsEmptyGroups() {
        let groups = ProjectGroup.group(sessions: [])
        XCTAssertTrue(groups.isEmpty)
    }

    func testMultipleSessionsWithDifferentCwdsCreateDistinctGroupsInEncounterOrder() {
        let s1 = Session(id: "s1", cwd: "/projects/alpha", title: "Alpha")
        let s2 = Session(id: "s2", cwd: "/projects/beta", title: "Beta")
        let s3 = Session(id: "s3", cwd: "/projects/gamma", title: "Gamma")

        let groups = ProjectGroup.group(sessions: [s1, s2, s3])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].workspacePath, "/projects/alpha")
        XCTAssertEqual(groups[0].id, "/projects/alpha")
        XCTAssertEqual(groups[0].title, "Alpha")
        XCTAssertEqual(groups[0].sessions, [s1])

        XCTAssertEqual(groups[1].workspacePath, "/projects/beta")
        XCTAssertEqual(groups[1].id, "/projects/beta")
        XCTAssertEqual(groups[1].title, "Beta")
        XCTAssertEqual(groups[1].sessions, [s2])

        XCTAssertEqual(groups[2].workspacePath, "/projects/gamma")
        XCTAssertEqual(groups[2].id, "/projects/gamma")
        XCTAssertEqual(groups[2].title, "Gamma")
        XCTAssertEqual(groups[2].sessions, [s3])
    }

    func testMultipleSessionsWithIdenticalStandardizedCwdAreMerged() {
        let s1 = Session(id: "s1", cwd: "/path/to/./dir", title: "Dir One")
        let s2 = Session(id: "s2", cwd: "/path/to/dir", title: "Dir Two")
        let s3 = Session(id: "s3", cwd: "/path/to/dir/", title: "Dir Three")

        let groups = ProjectGroup.group(sessions: [s1, s2, s3])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].workspacePath, "/path/to/dir")
        XCTAssertEqual(groups[0].id, "/path/to/dir")
        XCTAssertEqual(groups[0].title, "Dir One")
        XCTAssertEqual(groups[0].sessions, [s1, s2, s3])
    }

    func testUrgencyBucketPrecedence() {
        // Session A (.idle) + Session B (.working) -> group bucket is .active
        let idleSession = Session(id: "s1", cwd: "/proj", title: "T1", state: .ready)
        let workingSession = Session(id: "s2", cwd: "/proj", title: "T2", state: .working)
        let activeGroup = ProjectGroup(workspacePath: "/proj", sessions: [idleSession, workingSession])
        XCTAssertEqual(activeGroup.bucket, .active)

        // Session A (.working) + Session B (.waitingPermission) -> group bucket is .needsYou
        let waitingSession = Session(id: "s3", cwd: "/proj", title: "T3", state: .waitingPermission)
        let needsYouGroup = ProjectGroup(workspacePath: "/proj", sessions: [workingSession, waitingSession])
        XCTAssertEqual(needsYouGroup.bucket, .needsYou)

        // Session A (.idle) + Session B (.idle) -> group bucket is .idle
        let endedSession = Session(id: "s4", cwd: "/proj", title: "T4", state: .ended)
        let idleGroup = ProjectGroup(workspacePath: "/proj", sessions: [idleSession, endedSession])
        XCTAssertEqual(idleGroup.bucket, .idle)

        // Empty sessions -> .idle
        let emptyGroup = ProjectGroup(workspacePath: "/proj", sessions: [])
        XCTAssertEqual(emptyGroup.bucket, .idle)

        // Additional states that map to .needsYou: .waitingIdle, .finished, .error
        let finishedSession = Session(id: "s5", cwd: "/proj", title: "T5", state: .finished)
        XCTAssertEqual(ProjectGroup(workspacePath: "/proj", sessions: [finishedSession, workingSession]).bucket, .needsYou)

        let errorSession = Session(id: "s6", cwd: "/proj", title: "T6", state: .error)
        XCTAssertEqual(ProjectGroup(workspacePath: "/proj", sessions: [errorSession]).bucket, .needsYou)

        let waitingIdleSession = Session(id: "s7", cwd: "/proj", title: "T7", state: .waitingIdle)
        XCTAssertEqual(ProjectGroup(workspacePath: "/proj", sessions: [waitingIdleSession]).bucket, .needsYou)
    }

    func testGroupTitleDefaultsToFirstSessionTitleOrPathBasename() {
        // Defaults to first session title if present
        let s1 = Session(id: "s1", cwd: "/workspace/my-app", title: "App Title")
        let s2 = Session(id: "s2", cwd: "/workspace/my-app", title: "Worker")
        let g1 = ProjectGroup.group(sessions: [s1, s2])
        XCTAssertEqual(g1.first?.title, "App Title")

        // Falls back to path basename if first session title is empty
        let sEmpty = Session(id: "s3", cwd: "/workspace/backend-api", title: "")
        let g2 = ProjectGroup.group(sessions: [sEmpty])
        XCTAssertEqual(g2.first?.title, "backend-api")

        // Direct initialization with explicit title
        let gExplicit = ProjectGroup(workspacePath: "/workspace/custom", title: "Custom Title")
        XCTAssertEqual(gExplicit.title, "Custom Title")

        // Direct initialization without title falls back to path basename
        let gBasename = ProjectGroup(workspacePath: "/workspace/tooling")
        XCTAssertEqual(gBasename.title, "tooling")
    }

    func testEquatableConformance() {
        let s1 = Session(id: "s1", cwd: "/workspace/demo", title: "Demo")
        let g1 = ProjectGroup(workspacePath: "/workspace/demo", title: "Demo", sessions: [s1])
        let g2 = ProjectGroup(workspacePath: "/workspace/demo", title: "Demo", sessions: [s1])
        let g3 = ProjectGroup(workspacePath: "/workspace/demo2", title: "Demo", sessions: [s1])

        XCTAssertEqual(g1, g2)
        XCTAssertNotEqual(g1, g3)
    }
}
