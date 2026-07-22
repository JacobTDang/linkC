import XCTest
@testable import LinkCKit

/// The tool-server tracker over a fake runner: refresh parses and groups, actions carry the
/// exact CLI contracts and re-read state, failures and a missing docker are loud.
@MainActor
final class ToolServerServiceTests: XCTestCase {

    private let psJSON = """
    {"ID":"c1","Names":"firecrawl-api-1","Image":"firecrawl-api","State":"running","Status":"Up","HealthStatus":"none","Ports":"127.0.0.1:3002->3002/tcp","Labels":"com.docker.compose.project=firecrawl,com.docker.compose.service=api,com.docker.compose.project.working_dir=/tools/firecrawl"}
    {"ID":"c2","Names":"lonely","Image":"redis:7","State":"exited","Status":"Exited","HealthStatus":"none","Ports":"","Labels":""}
    """

    func testRefreshParsesAndGroups() async {
        let runner = FakeRunner(result: .success(psJSON))
        let service = ToolServerService(dockerPath: "/fake/docker", runner: runner)

        await service.refresh()

        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.projects.map(\.name), ["firecrawl"])
        XCTAssertEqual(service.projects[0].containers.map(\.id), ["c1"])
        XCTAssertEqual(service.standalone.map(\.id), ["c2"])
        XCTAssertEqual(runner.calls.first?.args, ["ps", "--all", "--format", "json"])
    }

    func testContainerActionContractAndRefresh() async {
        let runner = FakeRunner(result: .success(psJSON))
        let service = ToolServerService(dockerPath: "/fake/docker", runner: runner)

        await service.containerAction(.restart, id: "c1")

        let args = runner.calls.map(\.args)
        XCTAssertTrue(args.contains(["restart", "c1"]))
        XCTAssertEqual(args.last, ["ps", "--all", "--format", "json"], "actions re-read state")
        XCTAssertNil(service.busyTarget)
    }

    func testProjectActionContract() async {
        let runner = FakeRunner(result: .success(psJSON))
        let service = ToolServerService(dockerPath: "/fake/docker", runner: runner)

        await service.projectAction(.stop, name: "firecrawl")

        XCTAssertTrue(runner.calls.map(\.args).contains(["compose", "-p", "firecrawl", "stop"]))
    }

    func testRunnerFailureIsLoud() async {
        let runner = FakeRunner(result: .failure(LinkCError.process("Cannot connect to the Docker daemon")))
        let service = ToolServerService(dockerPath: "/fake/docker", runner: runner)

        await service.refresh()

        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.lastError!.contains("Docker daemon"))
    }

    func testMissingDockerIsExplainedWithoutRunning() async {
        let runner = FakeRunner(result: .success(psJSON))
        let service = ToolServerService(dockerPath: nil, runner: runner)

        await service.refresh()

        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.lastError!.lowercased().contains("docker"))
        XCTAssertTrue(runner.calls.isEmpty, "no docker binary, no subprocess")
    }
}
