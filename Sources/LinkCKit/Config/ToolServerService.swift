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
    public private(set) var projects: [ToolServerProject] = []
    public private(set) var standalone: [ContainerInfo] = []
    public private(set) var isRefreshing = false
    /// The container id or project name with a CLI action in flight — its controls disable.
    public private(set) var busyTarget: String?
    public private(set) var lastError: String?

    public let dockerPath: String?

    private let runner: any ProcessRunner
    private static let listTimeout: TimeInterval = 15
    /// `docker stop` waits out each container's grace period; compose does it per service.
    private static let actionTimeout: TimeInterval = 60

    public init(
        dockerPath: String? = DockerLocator.resolve(),
        runner: any ProcessRunner = LiveProcessRunner()
    ) {
        self.dockerPath = dockerPath
        self.runner = runner
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
            lastError = nil
        } catch {
            lastError = "Couldn't list containers: \(error.localizedDescription)"
        }
    }

    public func containerAction(_ action: ContainerAction, id: String) async {
        await perform(target: id, args: [action.rawValue, id])
    }

    public func projectAction(_ action: ProjectAction, name: String) async {
        await perform(target: name, args: ["compose", "-p", name, action.rawValue])
    }

    private func perform(target: String, args: [String]) async {
        guard let dockerPath, busyTarget == nil else { return }
        busyTarget = target
        defer { busyTarget = nil }
        do {
            _ = try await runner.run(dockerPath, args: args, cwd: nil, timeout: Self.actionTimeout)
            lastError = nil
        } catch {
            lastError = "docker \(args.joined(separator: " ")) failed: \(error.localizedDescription)"
        }
        await refresh()
    }
}
