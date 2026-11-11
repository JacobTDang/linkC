import XCTest
@testable import LinkCKit

final class KnownProjectsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-known-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func project(_ path: String, _ sessions: [KnownProject.OpenSession] = []) -> KnownProject {
        KnownProject(path: path, sessions: sessions)
    }

    // MARK: - The file

    func testTheFileRoundTrips() throws {
        let file = KnownProjectsFile(url: dir.appendingPathComponent("projects.json"))
        let projects = [
            project("/p/money-printer", [KnownProject.OpenSession(id: "S1", agent: "claude", activity: .idle)]),
            project("/p/nemo_ib", [KnownProject.OpenSession(id: "S2", agent: "codex", activity: .busy)])
        ]
        try file.write(projects)
        XCTAssertEqual(try file.read(), projects)
    }

    func testAMissingFileMeansLinkCIsNotRunning() {
        let file = KnownProjectsFile(url: dir.appendingPathComponent("projects.json"))
        XCTAssertThrowsError(try file.read()) { error in
            XCTAssertEqual(error as? KnownProjectsError, .linkCNotRunning)
        }
    }

    func testAnUnreadableFileIsAnErrorNotAnEmptyList() throws {
        let url = dir.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try KnownProjectsFile(url: url).read()) { error in
            guard case .unreadable = error as? KnownProjectsError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    func testRemovingTheFileThenReadingSaysLinkCIsNotRunning() throws {
        let file = KnownProjectsFile(url: dir.appendingPathComponent("projects.json"))
        try file.write([project("/p/a")])
        try file.remove()
        try file.remove()
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? KnownProjectsError, .linkCNotRunning) }
    }

    func testAnAgentThisBuildDoesNotKnowStillReads() throws {
        let file = KnownProjectsFile(url: dir.appendingPathComponent("projects.json"))
        try file.write([project("/p/a", [KnownProject.OpenSession(id: "S1", agent: "future-agent", activity: .idle)])])
        let read = try file.read()
        XCTAssertEqual(read.first?.sessions.first?.agent, "future-agent")
        XCTAssertNil(read.first?.sessions.first?.agentKind)
    }

    func testTheNameIsTheFolderName() {
        XCTAssertEqual(project("/Users/j/Projects/nemo_ib").name, "nemo_ib")
    }

    // MARK: - Resolving a project argument

    private let known = [
        KnownProject(path: "/p/money-printer", sessions: []),
        KnownProject(path: "/p/nemo_ib", sessions: []),
        KnownProject(path: "/q/api", sessions: []),
        KnownProject(path: "/r/api", sessions: [])
    ]

    func testANameMatchesIgnoringCase() throws {
        XCTAssertEqual(try ProjectRef.resolve("NEMO_IB", among: known, caller: "/p/money-printer").path, "/p/nemo_ib")
    }

    func testAFullPathMatches() throws {
        XCTAssertEqual(try ProjectRef.resolve("/p/nemo_ib", among: known, caller: "/p/money-printer").path, "/p/nemo_ib")
    }

    func testAPathWithATrailingSlashMatches() throws {
        XCTAssertEqual(try ProjectRef.resolve("/p/nemo_ib/", among: known, caller: "/p/money-printer").path, "/p/nemo_ib")
    }

    func testAnUnknownNameListsTheKnownNamesOtherThanTheCallers() {
        XCTAssertThrowsError(try ProjectRef.resolve("nope", among: known, caller: "/p/money-printer")) { error in
            XCTAssertEqual(error as? ProjectRefError, .unknown("nope", known: ["api", "api", "nemo_ib"]))
        }
    }

    func testAnUnknownPathIsRefused() {
        XCTAssertThrowsError(try ProjectRef.resolve("/p/elsewhere", among: known, caller: "/p/money-printer")) { error in
            XCTAssertEqual(error as? ProjectRefError, .unknown("/p/elsewhere", known: ["api", "api", "nemo_ib"]))
        }
    }

    func testANameTwoFoldersShareListsTheirPaths() {
        XCTAssertThrowsError(try ProjectRef.resolve("api", among: known, caller: "/p/money-printer")) { error in
            XCTAssertEqual(error as? ProjectRefError, .ambiguous("api", paths: ["/q/api", "/r/api"]))
        }
    }

    func testTheCallersOwnProjectIsRefusedByName() {
        XCTAssertThrowsError(try ProjectRef.resolve("money-printer", among: known, caller: "/p/money-printer")) { error in
            XCTAssertEqual(error as? ProjectRefError, .own("money-printer"))
        }
    }

    func testTheCallersOwnProjectIsRefusedByPath() {
        XCTAssertThrowsError(try ProjectRef.resolve("/p/money-printer", among: known, caller: "/p/money-printer")) { error in
            XCTAssertEqual(error as? ProjectRefError, .own("/p/money-printer"))
        }
    }

    func testANameSharedWithTheCallersOwnFolderGoesToTheOtherOne() throws {
        let projects = [KnownProject(path: "/p/api", sessions: []), KnownProject(path: "/q/api", sessions: [])]
        XCTAssertEqual(try ProjectRef.resolve("api", among: projects, caller: "/p/api").path, "/q/api")
    }

    func testAnEmptyReferenceIsRefused() {
        XCTAssertThrowsError(try ProjectRef.resolve("  ", among: known, caller: "/p/money-printer")) { error in
            XCTAssertEqual(error as? ProjectRefError, .unknown("", known: ["api", "api", "nemo_ib"]))
        }
    }

    func testEachRefusalSaysWhatToDo() {
        XCTAssertEqual(ProjectRefError.own("x").errorDescription, "\"x\" is this project. Use the tool without project.")
        XCTAssertEqual(ProjectRefError.ambiguous("api", paths: ["/q/api", "/r/api"]).errorDescription,
                       "\"api\" names more than one project: /q/api, /r/api. Pass the full path.")
        XCTAssertEqual(ProjectRefError.unknown("nope", known: ["nemo_ib"]).errorDescription,
                       "No project \"nope\" is known to linkC. Known projects: nemo_ib.")
        XCTAssertEqual(ProjectRefError.unknown("nope", known: []).errorDescription,
                       "No project \"nope\" is known to linkC. No other project is known.")
        XCTAssertEqual(KnownProjectsError.linkCNotRunning.errorDescription,
                       "linkC isn't running, so other projects can't be reached.")
    }
}
