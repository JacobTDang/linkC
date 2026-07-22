import Foundation

public enum ContainerState: String, Sendable, Equatable {
    case running, exited, other

    init(raw: String?) {
        switch raw {
        case "running": self = .running
        case "exited": self = .exited
        default: self = .other
        }
    }
}

/// One container as reported by `docker ps --all --format json`, with its compose identity
/// lifted out of the label blob.
public struct ContainerInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    public let state: ContainerState
    public let health: String
    public let ports: String
    public let composeProject: String?
    public let composeService: String?
    public let composeWorkingDir: String?

    public init(
        id: String, name: String, image: String, state: ContainerState, health: String,
        ports: String, composeProject: String?, composeService: String?, composeWorkingDir: String?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.health = health
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.composeWorkingDir = composeWorkingDir
    }
}

/// Parses `docker ps --all --format json`: newline-delimited JSON, one container per line.
/// Unparseable lines are skipped (selection, not failure — docker interleaves warnings on
/// stderr, but a defensive parser costs nothing).
public enum DockerPS {
    public static func parse(_ output: String) -> [ContainerInfo] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawContainer.self, from: data),
                  let id = raw.id, let name = raw.names else { return nil }
            let labels = parseLabels(raw.labels ?? "")
            return ContainerInfo(
                id: id,
                name: name,
                image: raw.image ?? "",
                state: ContainerState(raw: raw.state),
                health: raw.healthStatus ?? "none",
                ports: raw.ports ?? "",
                composeProject: labels["com.docker.compose.project"],
                composeService: labels["com.docker.compose.service"],
                composeWorkingDir: labels["com.docker.compose.project.working_dir"]
            )
        }
    }

    /// Docker joins labels as "k=v,k=v". Values can contain "=" (split on the first only);
    /// they cannot contain "," in the compose labels we read.
    private static func parseLabels(_ blob: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in blob.split(separator: ",") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            labels[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return labels
    }

    private struct RawContainer: Decodable {
        let id: String?
        let names: String?
        let image: String?
        let state: String?
        let healthStatus: String?
        let ports: String?
        let labels: String?

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case names = "Names"
            case image = "Image"
            case state = "State"
            case healthStatus = "HealthStatus"
            case ports = "Ports"
            case labels = "Labels"
        }
    }
}

/// A compose project as one "tool server" — the unit the user thinks in.
public struct ToolServerProject: Equatable, Sendable, Identifiable {
    public let name: String
    public let workingDir: String?
    public let containers: [ContainerInfo]

    public var id: String { name }
    public var runningCount: Int { containers.count { $0.state == .running } }
}

/// Pure grouping: compose projects (sorted by name, containers by service) + standalone.
public enum ToolServerCatalog {
    public static func group(
        _ containers: [ContainerInfo]
    ) -> (projects: [ToolServerProject], standalone: [ContainerInfo]) {
        let composed = containers.filter { $0.composeProject != nil }
        let standalone = containers.filter { $0.composeProject == nil }.sorted { $0.name < $1.name }

        let projects = Dictionary(grouping: composed) { $0.composeProject! }
            .map { name, members in
                ToolServerProject(
                    name: name,
                    workingDir: members.compactMap(\.composeWorkingDir).first,
                    containers: members.sorted { ($0.composeService ?? $0.name) < ($1.composeService ?? $1.name) }
                )
            }
            .sorted { $0.name < $1.name }
        return (projects, standalone)
    }
}

/// Docker binary probing — fixed candidates because Finder-launched apps carry a minimal
/// PATH. nil when docker isn't installed; the screen says so instead of guessing.
public enum DockerLocator {
    public static let defaultCandidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker",
    ]

    public static func resolve(
        candidates: [String] = defaultCandidates,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }
}
