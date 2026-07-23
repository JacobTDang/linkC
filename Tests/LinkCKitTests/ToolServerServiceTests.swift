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
        XCTAssertEqual(args.last, ["images", "--format", "json"], "actions re-read state (refresh ends with images)")
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

    private func makeStacksDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-svc-stacks-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    func testRefreshRemembersStacksAndComputesCold() async {
        let dir = makeStacksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stacks = KnownStacksStore(directory: dir)
        stacks.remember(name: "ghost-stack", workingDir: "/tools/ghost")
        let service = ToolServerService(
            dockerPath: "/fake/docker", runner: FakeRunner(result: .success(psJSON)), knownStacks: stacks
        )

        await service.refresh()

        // The live firecrawl project was remembered; ghost-stack has no live containers → cold.
        XCTAssertTrue(stacks.stacks.contains { $0.name == "firecrawl" && $0.workingDir == "/tools/firecrawl" })
        XCTAssertEqual(service.coldStacks.map(\.name), ["ghost-stack"])
    }

    func testUpDownPullPruneContracts() async {
        let dir = makeStacksDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeRunner(result: .success(psJSON))
        let service = ToolServerService(
            dockerPath: "/fake/docker", runner: runner, knownStacks: KnownStacksStore(directory: dir)
        )

        await service.stackUp(KnownStack(name: "firecrawl", workingDir: "/tools/firecrawl"))
        await service.projectDown(name: "firecrawl")
        await service.pullImage("firecrawl-api:latest")
        await service.pruneDanglingImages()

        let args = runner.calls.map(\.args)
        XCTAssertTrue(args.contains(["compose", "-p", "firecrawl", "--project-directory", "/tools/firecrawl", "up", "-d"]))
        XCTAssertTrue(args.contains(["compose", "-p", "firecrawl", "down"]))
        XCTAssertTrue(args.contains(["pull", "firecrawl-api:latest"]))
        XCTAssertTrue(args.contains(["image", "prune", "-f"]))
        XCTAssertEqual(args.last, ["images", "--format", "json"], "every action re-reads state (refresh ends with images)")
    }

    func testRefreshListsImages() async {
        // FakeRunner returns the same output per call, so image parsing tolerating ps JSON
        // (yielding zero images) is the honest assertion here; the images-args contract is what matters.
        let runner = FakeRunner(result: .success(psJSON))
        let service = ToolServerService(
            dockerPath: "/fake/docker", runner: runner,
            knownStacks: KnownStacksStore(directory: makeStacksDir())
        )
        await service.refresh()
        XCTAssertTrue(runner.calls.map(\.args).contains(["images", "--format", "json"]))
    }

    func testLoadDetailComposesAndDegradesPerPart() async {
        let inspectJSON = """
        [{"RestartCount":0,"State":{"Status":"running","StartedAt":"2026-07-20T18:46:09Z"},\
        "Config":{"Image":"img","Env":["A=1"]},"Mounts":[],"NetworkSettings":{"Ports":{}}}]
        """
        let runner = FakeRunner(result: .success(inspectJSON))
        let service = ToolServerService(
            dockerPath: "/fake/docker", runner: runner,
            knownStacks: KnownStacksStore(directory: makeStacksDir())
        )

        let detail = await service.loadDetail(id: "c1")

        XCTAssertEqual(detail?.overview?.image, "img")
        XCTAssertNil(detail?.stats, "stats output wasn't stats JSON — degrades to nil, not failure")
        XCTAssertNotNil(detail?.logTail, "raw text is a valid log tail")
        let args = runner.calls.map(\.args)
        XCTAssertTrue(args.contains(["inspect", "c1"]))
        XCTAssertTrue(args.contains(["stats", "--no-stream", "--format", "json", "c1"]))
        XCTAssertTrue(args.contains(["logs", "--tail", "40", "c1"]))
    }
}
