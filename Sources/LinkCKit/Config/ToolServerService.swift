import Foundation
import Observation

public enum ContainerAction: String, Sendable {
    case start, stop, restart
}

public enum ProjectAction: String, Sendable {
    case stop, restart
}

/// The tool-server tracker: compose projects (the services the user's tools depend on) and
/// standalone containers, from `docker ps` through the shared runner. Light management goes
/// through the docker CLI and always re-reads authoritative state. A machine without docker
/// (or with the daemon down) says so plainly instead of pretending emptiness.
@MainActor
@Observable
public final class ToolServerService {
    /// Everything a container's drill-in shows — each part degrades to nil independently
    /// (a stats hiccup must not blank the overview).
    public struct DetailBundle: Sendable {
        public let overview: ContainerDetail?
        public let stats: ContainerStats?
        public let logTail: String?
    }

    public private(set) var projects: [ToolServerProject] = []
    public private(set) var standalone: [ContainerInfo] = []
    public private(set) var images: [ImageInfo] = []
    public private(set) var isRefreshing = false
    /// The container id or project name with a CLI action in flight — its controls disable.
    public private(set) var busyTarget: String?
    public private(set) var lastError: String?

    public let dockerPath: String?
    public let knownStacks: KnownStacksStore

    /// Remembered compose projects with no live containers — shown dim, with Up.
    public var coldStacks: [KnownStack] {
        let liveNames = Set(projects.map(\.name))
        return knownStacks.stacks.filter { !liveNames.contains($0.name) }
    }

    private let runner: any ProcessRunner
    private static let listTimeout: TimeInterval = 15
    /// `docker stop` waits out each container's grace period; compose does it per service.
    private static let actionTimeout: TimeInterval = 60
    /// `compose up` may pull/build images.
    private static let upTimeout: TimeInterval = 120

    public init(
        dockerPath: String? = DockerLocator.resolve(),
        runner: any ProcessRunner = LiveProcessRunner(),
        knownStacks: KnownStacksStore = KnownStacksStore(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("linkC")
        )
    ) {
        self.dockerPath = dockerPath
        self.runner = runner
        self.knownStacks = knownStacks
    }

    public func refresh() async {
        guard let dockerPath else {
            lastError = "Docker isn't installed (looked in \(DockerLocator.defaultCandidates.joined(separator: ", ")))."
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await runner.run(
                dockerPath, args: ["ps", "--all", "--format", "json"], cwd: nil, timeout: Self.listTimeout
            )
            let grouped = ToolServerCatalog.group(DockerPS.parse(output))
            projects = grouped.projects
            standalone = grouped.standalone
            // Every live compose project is worth remembering — that's what lets a downed
            // stack come back as a cold card instead of vanishing.
            for project in grouped.projects {
                if let dir = project.workingDir {
                    knownStacks.remember(name: project.name, workingDir: dir)
                }
            }
            lastError = nil
        } catch {
            lastError = "Couldn't list containers: \(error.localizedDescription)"
        }
        // Images are additive: a failure here surfaces but doesn't clobber the container list.
        do {
            let output = try await runner.run(
                dockerPath, args: ["images", "--format", "json"], cwd: nil, timeout: Self.listTimeout
            )
            images = DockerImages.parse(output)
        } catch {
            lastError = "Couldn't list images: \(error.localizedDescription)"
        }
    }

    public func containerAction(_ action: ContainerAction, id: String) async {
        await perform(target: id, args: [action.rawValue, id])
    }

    public func projectAction(_ action: ProjectAction, name: String) async {
        await perform(target: name, args: ["compose", "-p", name, action.rawValue])
    }

    /// Bring a remembered stack up from cold. Long timeout: up may pull or build.
    public func stackUp(_ stack: KnownStack) async {
        await perform(
            target: stack.name,
            args: ["compose", "-p", stack.name, "--project-directory", stack.workingDir, "up", "-d"],
            timeout: Self.upTimeout
        )
    }

    /// `down` removes the project's containers (unlike stop) — the cold-card copy says so.
    public func projectDown(name: String) async {
        await perform(target: name, args: ["compose", "-p", name, "down"], timeout: Self.upTimeout)
    }

    public func pullImage(_ reference: String) async {
        await perform(target: reference, args: ["pull", reference], timeout: Self.upTimeout)
    }

    /// Dangling images only — never volumes (data lives there; reclaiming rebuildable disk
    /// is the whole scope).
    public func pruneDanglingImages() async {
        await perform(target: "prune", args: ["image", "prune", "-f"])
    }

    /// The drill-in's data, composed from three independent CLI calls — each part nil on
    /// its own failure rather than failing the bundle.
    public func loadDetail(id: String) async -> DetailBundle? {
        guard let dockerPath else { return nil }
        async let inspect = try? runner.run(dockerPath, args: ["inspect", id], cwd: nil, timeout: Self.listTimeout)
        async let stats = try? runner.run(dockerPath, args: ["stats", "--no-stream", "--format", "json", id], cwd: nil, timeout: Self.listTimeout)
        async let logs = try? runner.run(dockerPath, args: ["logs", "--tail", "40", id], cwd: nil, timeout: Self.listTimeout)

        let (inspectOut, statsOut, logsOut) = await (inspect, stats, logs)
        return DetailBundle(
            overview: inspectOut.flatMap { DockerInspect.parse(Data($0.utf8)) },
            stats: statsOut.flatMap { DockerStats.parse($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            logTail: logsOut?.isEmpty == false ? logsOut : nil
        )
    }

    private func perform(target: String, args: [String], timeout: TimeInterval = actionTimeout) async {
        guard let dockerPath, busyTarget == nil else { return }
        busyTarget = target
        defer { busyTarget = nil }
        do {
            _ = try await runner.run(dockerPath, args: args, cwd: nil, timeout: timeout)
            lastError = nil
        } catch {
            lastError = "docker \(args.joined(separator: " ")) failed: \(error.localizedDescription)"
        }
        await refresh()
    }
}
