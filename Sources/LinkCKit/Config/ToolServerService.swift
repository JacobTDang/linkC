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
    /// Last batch `docker stats` sweep, keyed by container id — the per-container power proxy.
    public private(set) var statsById: [String: ContainerStats] = [:]
    /// The in-flight follow-up sweep, exposed so tests (and any caller needing fresh figures
    /// right now) can await it deterministically.
    public private(set) var statsSweepTask: Task<Void, Never>?
    private var isSweepingStats = false
    /// Docker's VM tax — the Linux VM's host CPU, which no per-container stat can show.
    /// Nil while the VM isn't running.
    public private(set) var vmCpu: Double?
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
            // The daemon is unreachable — stop here. Running images/stats against it would
            // only burn timeouts and clobber this root-cause message with theirs.
            lastError = "Couldn't list containers: \(error.localizedDescription)"
            return
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
        // The VM tax rides along every refresh: one host `ps`, attributed by parentage.
        // It matters MOST when containers idle — that's when the VM is the whole cost.
        do {
            let output = try await runner.run(
                "/bin/ps", args: ["-Ao", "pid=,ppid=,pcpu=,comm="], cwd: nil, timeout: Self.listTimeout
            )
            vmCpu = DockerVM.parse(output)
        } catch {
            vmCpu = nil   // a ps hiccup is not a docker error — hide the row, don't shout
        }
        // The power proxy rides behind refresh as a follow-up task: `docker stats
        // --no-stream` blocks ~2s sampling, and neither container actions (which await
        // refresh before re-enabling their controls) nor the manual refresh spinner
        // should pay that. Results land when the sample does.
        statsSweepTask = Task { await self.sweepStats() }
    }

    /// One batch stats sample of every running container. Skipped when nothing runs; one
    /// sweep at a time (the 15s sidebar poll can lap a slow daemon).
    private func sweepStats() async {
        guard let dockerPath, !isSweepingStats else { return }
        let anythingRunning = projects.contains { $0.runningCount > 0 }
            || standalone.contains { $0.state == .running }
        guard anythingRunning else {
            statsById = [:]
            return
        }
        isSweepingStats = true
        defer { isSweepingStats = false }
        do {
            let output = try await runner.run(
                dockerPath, args: ["stats", "--no-stream", "--format", "json"], cwd: nil, timeout: Self.listTimeout
            )
            statsById = DockerStats.parseAll(output)
        } catch {
            // Keep the last reading rather than blanking the column mid-hiccup.
            lastError = "Couldn't sample container stats: \(error.localizedDescription)"
        }
    }

    public func containerAction(_ action: ContainerAction, id: String) async {
        await perform(target: id, args: [action.rawValue, id])
    }

    public func projectAction(_ action: ProjectAction, name: String) async {
        await perform(target: name, args: ["compose", "-p", name, action.rawValue])
    }

    /// Register a compose project from its folder — the "Add stack…" path, so a stack linkC
    /// has never seen running still gets a cold card with Up. Validates through
    /// `compose config`, which also yields the canonical project name compose itself would
    /// use — a later `docker ps` discovery then upserts the same entry instead of duplicating.
    /// Returns nil (with `lastError` set) when the folder has no compose file or the file
    /// doesn't parse.
    @discardableResult
    public func addStack(directory: String) async -> KnownStack? {
        guard let dockerPath else {
            lastError = "Docker isn't installed (looked in \(DockerLocator.defaultCandidates.joined(separator: ", ")))."
            return nil
        }
        guard ComposeFile.locate(in: directory) != nil else {
            lastError = "No compose file in \((directory as NSString).abbreviatingWithTildeInPath) — expected \(ComposeFile.candidates.joined(separator: ", "))."
            return nil
        }
        do {
            let output = try await runner.run(
                dockerPath,
                args: ["compose", "--project-directory", directory, "config", "--format", "json"],
                cwd: nil, timeout: Self.listTimeout
            )
            let config = try ComposeConfig.parse(Data(output.utf8))
            knownStacks.remember(name: config.name, workingDir: directory, services: config.services)
            lastError = nil
            return knownStacks.stacks.first { $0.name == config.name }
        } catch {
            lastError = "Couldn't read the compose project: \(error.localizedDescription)"
            return nil
        }
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
