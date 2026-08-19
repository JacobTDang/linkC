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

/// `docker inspect` extraction: the overview fields, with env VALUES discarded at parse —
/// container env routinely holds secrets, and the detail view shows key names only.
final class DockerInspectTests: XCTestCase {

    private let realInspect = """
    [{"Id":"90b2","RestartCount":2,
      "State":{"Status":"running","StartedAt":"2026-07-20T18:46:09.047810921Z","Running":true},
      "Config":{"Image":"firecrawl-api","Env":["SUPABASE_SERVICE_TOKEN=sk-SECRET","EXTRACT_WORKER_PORT=3004","PATH=/usr/bin"]},
      "Mounts":[{"Type":"volume","Source":"/var/lib/docker/volumes/firecrawl_fdb","Destination":"/var/fdb"}],
      "NetworkSettings":{"Ports":{"3002/tcp":[{"HostIp":"127.0.0.1","HostPort":"3002"}],"9000/tcp":null}}}]
    """

    func testParsesOverviewWithEnvKeysOnly() throws {
        let detail = try XCTUnwrap(DockerInspect.parse(realInspect.data(using: .utf8)!))
        XCTAssertEqual(detail.image, "firecrawl-api")
        XCTAssertEqual(detail.status, "running")
        XCTAssertEqual(detail.restartCount, 2)
        XCTAssertEqual(detail.startedAt?.timeIntervalSince1970 ?? 0, 1_784_573_169, accuracy: 2)
        XCTAssertEqual(detail.envKeys, ["EXTRACT_WORKER_PORT", "PATH", "SUPABASE_SERVICE_TOKEN"])
        XCTAssertEqual(detail.mounts, ["volume → /var/fdb"])
        XCTAssertEqual(detail.ports, ["3002/tcp → 127.0.0.1:3002"])
        XCTAssertFalse(String(describing: detail).contains("SECRET"), "env values must never survive parsing")
    }

    func testMalformedIsNil() {
        XCTAssertNil(DockerInspect.parse("[]".data(using: .utf8)!))
        XCTAssertNil(DockerInspect.parse("nope".data(using: .utf8)!))
    }
}

/// `docker stats --no-stream --format json`: the formatted strings pass through untouched.
final class DockerStatsTests: XCTestCase {

    func testParsesRealLine() throws {
        let line = #"{"CPUPerc":"2.10%","MemUsage":"2.772GiB / 7.749GiB","ID":"90b2","Name":"firecrawl-api-1"}"#
        let stats = try XCTUnwrap(DockerStats.parse(line))
        XCTAssertEqual(stats.cpu, "2.10%")
        XCTAssertEqual(stats.memory, "2.772GiB / 7.749GiB")
    }

    func testGarbageIsNil() {
        XCTAssertNil(DockerStats.parse("no json"))
    }

    /// The batch sweep — one line per running container, keyed by id — is the sidebar's
    /// power proxy. Garbage lines are skipped alone; cpuValue turns "188.85%" numeric.
    func testParseAllKeysByIdAndSkipsGarbage() {
        let output = """
        {"ID":"abc123","Name":"firecrawl-playwright-service-1","CPUPerc":"188.85%","MemUsage":"1.2GiB / 8GiB"}
        not json
        {"ID":"def456","Name":"firecrawl-rabbitmq-1","CPUPerc":"48.73%","MemUsage":"200MiB / 8GiB"}
        """
        let stats = DockerStats.parseAll(output)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats["abc123"]?.cpu, "188.85%")
        XCTAssertEqual(stats["abc123"]?.cpuValue ?? 0, 188.85, accuracy: 0.01)
        XCTAssertEqual(stats["def456"]?.memory, "200MiB / 8GiB")
        XCTAssertEqual(stats["def456"]?.cpuValue ?? 0, 48.73, accuracy: 0.01)
    }

    func testCpuValueToleratesUnparseable() {
        XCTAssertEqual(ContainerStats(cpu: "--", memory: "").cpuValue, 0)
    }
}

/// `docker images --format json`: newline-delimited; dangling = `<none>` repository.
final class DockerImagesTests: XCTestCase {

    func testParsesRealLines() {
        let lines = """
        {"ID":"3020cb9199c3","Repository":"firecrawl-firecrawl-proxy","Tag":"latest","Size":"229MB","CreatedSince":"20 hours ago"}
        {"ID":"dead00000000","Repository":"\\u003cnone\\u003e","Tag":"\\u003cnone\\u003e","Size":"1.2GB","CreatedSince":"3 weeks ago"}
        """
        let images = DockerImages.parse(lines)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].reference, "firecrawl-firecrawl-proxy:latest")
        XCTAssertFalse(images[0].isDangling)
        XCTAssertEqual(images[0].size, "229MB")
        XCTAssertTrue(images[1].isDangling)
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(DockerImages.parse("").isEmpty)
        XCTAssertTrue(DockerImages.parse("junk").isEmpty)
    }
}

/// Known stacks persist so a fully-downed compose project still shows (with Up) after
/// restart — the store is the WorkspaceManifest pattern: JSON file, tolerant load.
@MainActor
final class KnownStacksStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-stacks-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRememberPersistsAndUpserts() {
        let store = KnownStacksStore(directory: dir)
        store.remember(name: "firecrawl", workingDir: "/tools/firecrawl")
        store.remember(name: "firecrawl", workingDir: "/tools/firecrawl-v2")  // upsert wins

        let reloaded = KnownStacksStore(directory: dir)
        XCTAssertEqual(reloaded.stacks.count, 1)
        XCTAssertEqual(reloaded.stacks.first?.workingDir, "/tools/firecrawl-v2")
    }

    func testForgetRemoves() {
        let store = KnownStacksStore(directory: dir)
        store.remember(name: "x", workingDir: "/x")
        store.forget(name: "x")
        XCTAssertTrue(KnownStacksStore(directory: dir).stacks.isEmpty)
    }

    func testMissingAndCorruptFilesLoadEmpty() throws {
        XCTAssertTrue(KnownStacksStore(directory: dir).stacks.isEmpty)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!.write(to: dir.appendingPathComponent("known-stacks.json"))
        XCTAssertTrue(KnownStacksStore(directory: dir).stacks.isEmpty)
    }

    func testLegacyFileWithoutServicesLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"name":"firecrawl","workingDir":"/tools/firecrawl"}]"#.utf8)
            .write(to: dir.appendingPathComponent("known-stacks.json"))

        let store = KnownStacksStore(directory: dir)
        XCTAssertEqual(store.stacks.first?.name, "firecrawl")
        XCTAssertEqual(store.stacks.first?.services, [])
    }

    func testRememberWithServicesStoresThem() {
        let store = KnownStacksStore(directory: dir)
        store.remember(name: "firecrawl", workingDir: "/t", services: ["api", "worker"])
        XCTAssertEqual(KnownStacksStore(directory: dir).stacks.first?.services, ["api", "worker"])
    }

    func testRememberWithoutServicesPreservesExistingOnes() {
        let store = KnownStacksStore(directory: dir)
        store.remember(name: "firecrawl", workingDir: "/t", services: ["api"])
        store.remember(name: "firecrawl", workingDir: "/t")  // the ps-discovery path
        XCTAssertEqual(store.stacks.first?.services, ["api"], "ps discovery must not wipe known services")
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

/// The VM tax: Docker's Linux VM burns host CPU even with every container idle. The
/// parser attributes `com.apple.Virtualization.VirtualMachine` processes to Docker by
/// parentage (child of com.docker.backend) — another hypervisor's VM must not count.
final class DockerVMTests: XCTestCase {

    func testSumsDockerOwnedVMsOnly() {
        let ps = """
          500     1  0.2 /Applications/Docker.app/Contents/MacOS/com.docker.backend
          612   500  8.5 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
          700     1 22.0 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
          801     1  1.0 /Applications/UTM.app/Contents/MacOS/UTM
        """
        XCTAssertEqual(DockerVM.parse(ps) ?? -1, 8.5, accuracy: 0.01,
                       "only the backend-parented VM counts; the orphan VM belongs to someone else")
    }

    func testNoDockerVMIsNil() {
        let ps = """
          801     1  1.0 /Applications/UTM.app/Contents/MacOS/UTM
          900     1  0.1 /sbin/launchd
        """
        XCTAssertNil(DockerVM.parse(ps))

        // Backend alive but VM not yet booted (Docker starting): still nil, not 0.
        let starting = "  500     1  0.2 /Applications/Docker.app/Contents/MacOS/com.docker.backend"
        XCTAssertNil(DockerVM.parse(starting))
    }

    func testGarbageLinesAreSkippedAlone() {
        let ps = """
        not a ps line at all
          500     1  0.2 /Applications/Docker.app/Contents/MacOS/com.docker.backend
          612   500  4.25 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
        """
        XCTAssertEqual(DockerVM.parse(ps) ?? -1, 4.25, accuracy: 0.01)
    }
}
