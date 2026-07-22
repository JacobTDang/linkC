import XCTest
@testable import LinkCKit

/// Parses `docker ps --all --format json` — newline-delimited JSON, one container per line,
/// with compose identity buried in the comma-joined `Labels` string. Fixture lines mirror
/// the real output captured on this machine (unicode-escaped `->` in ports included).
final class DockerPSTests: XCTestCase {

    private let realLine = """
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-07-20 14:46:08 -0400 EDT",\
    "HealthStatus":"none","ID":"183ce062d3e3","Image":"4924bb3a24b5",\
    "Labels":"com.docker.compose.config-hash=270ade,com.docker.compose.project.working_dir=/Users/jacobdang/Desktop/tools/firecrawl,\
    com.docker.compose.project=firecrawl,com.docker.compose.service=firecrawl-proxy,desktop.docker.io/ports.scheme=v2",\
    "Names":"firecrawl-firecrawl-proxy-1","Ports":"127.0.0.1:3999-\\u003e3999/tcp",\
    "RunningFor":"2 days ago","State":"running","Status":"Up 19 hours"}
    """

    func testParsesRealComposeContainer() throws {
        let containers = DockerPS.parse(realLine + "\n")
        XCTAssertEqual(containers.count, 1)
        let c = try XCTUnwrap(containers.first)
        XCTAssertEqual(c.id, "183ce062d3e3")
        XCTAssertEqual(c.name, "firecrawl-firecrawl-proxy-1")
        XCTAssertEqual(c.state, .running)
        XCTAssertEqual(c.health, "none")
        XCTAssertEqual(c.ports, "127.0.0.1:3999->3999/tcp")
        XCTAssertEqual(c.composeProject, "firecrawl")
        XCTAssertEqual(c.composeService, "firecrawl-proxy")
        XCTAssertEqual(c.composeWorkingDir, "/Users/jacobdang/Desktop/tools/firecrawl")
    }

    func testStandaloneAndExitedContainers() throws {
        let lines = """
        {"ID":"aaa","Names":"lonely","Image":"redis:7","Labels":"","State":"exited","Status":"Exited (0) 2 hours ago","HealthStatus":"none","Ports":""}
        {"ID":"bbb","Names":"solo","Image":"nginx","Labels":"maintainer=someone","State":"running","Status":"Up","HealthStatus":"healthy","Ports":"80/tcp"}
        """
        let containers = DockerPS.parse(lines)
        XCTAssertEqual(containers.count, 2)
        XCTAssertNil(containers[0].composeProject)
        XCTAssertEqual(containers[0].state, .exited)
        XCTAssertEqual(containers[1].health, "healthy")
    }

    func testGarbageLinesAreSkippedNotFatal() {
        let containers = DockerPS.parse("not json\n{\"ID\":\"x\",\"Names\":\"n\",\"State\":\"running\"}\n")
        XCTAssertEqual(containers.map(\.id), ["x"])
    }

    func testEmptyOutputIsEmpty() {
        XCTAssertTrue(DockerPS.parse("").isEmpty)
    }
}

/// Grouping: one card per compose project, containers ordered by service name; everything
/// unlabeled falls into standalone.
final class ToolServerCatalogTests: XCTestCase {

    private func container(
        id: String, project: String? = nil, service: String? = nil, state: ContainerState = .running
    ) -> ContainerInfo {
        ContainerInfo(id: id, name: id, image: "img", state: state, health: "none",
                      ports: "", composeProject: project, composeService: service,
                      composeWorkingDir: project.map { "/stacks/\($0)" })
    }

    func testGroupsByProjectSortedWithStandaloneSeparate() {
        let grouped = ToolServerCatalog.group([
            container(id: "b1", project: "beta", service: "web"),
            container(id: "solo"),
            container(id: "a2", project: "alpha", service: "worker"),
            container(id: "a1", project: "alpha", service: "api"),
        ])
        XCTAssertEqual(grouped.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(grouped.projects[0].containers.map(\.id), ["a1", "a2"], "sorted by service")
        XCTAssertEqual(grouped.projects[0].workingDir, "/stacks/alpha")
        XCTAssertEqual(grouped.standalone.map(\.id), ["solo"])
    }

    func testProjectAggregates() {
        let grouped = ToolServerCatalog.group([
            container(id: "r", project: "p", service: "a"),
            container(id: "x", project: "p", service: "b", state: .exited),
        ])
        let project = grouped.projects[0]
        XCTAssertEqual(project.runningCount, 1)
        XCTAssertEqual(project.containers.count, 2)
    }
}

/// Docker binary probing — Finder-launched apps have a minimal PATH, so fixed candidates,
/// first executable wins, nil (not a guess) when docker isn't installed.
final class DockerLocatorTests: XCTestCase {

    func testFirstExistingCandidateWins() {
        let path = DockerLocator.resolve(
            candidates: ["/no/docker", "/bin/ls", "/bin/echo"],
            isExecutable: { $0 != "/no/docker" }
        )
        XCTAssertEqual(path, "/bin/ls")
    }

    func testNoDockerIsNilNotAGuess() {
        XCTAssertNil(DockerLocator.resolve(candidates: ["/a", "/b"], isExecutable: { _ in false }))
    }
}
