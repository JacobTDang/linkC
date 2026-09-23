import Foundation

/// Something linkC found running, reduced to what the map can be compared against.
public struct DiscoveredThing: Equatable, Sendable {
    /// The compose service name when there is one, else the container's name.
    public let name: String
    /// The image it runs, when known — what a proposed kind is guessed from.
    public let image: String?
    /// One line for the tooltip and the suggestion row.
    public let detail: String

    public init(name: String, image: String?, detail: String) {
        self.name = name
        self.image = image
        self.detail = detail
    }
}

/// What linkC can say about a component right now.
public enum ComponentStatus: Equatable, Sendable {
    /// Something running matches it.
    case present
    /// It says it runs where linkC can look, and it is not there.
    case missing
    /// linkC has no way to look for it — never drawn as absent.
    case unchecked
}

/// Something running that the map does not name.
public struct MapSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let kind: ComponentKind
    public let detail: String

    public init(name: String, kind: ComponentKind, detail: String) {
        self.name = name
        self.kind = kind
        self.detail = detail
    }
}

/// Compares a map against what discovery found. Pure: discovery results come in as values, and
/// nothing here reads a file or runs a process.
public enum SystemReconciler {
    public struct Reconciliation: Equatable, Sendable {
        public let statuses: [String: ComponentStatus]
        public let suggestions: [MapSuggestion]

        public init(statuses: [String: ComponentStatus], suggestions: [MapSuggestion]) {
            self.statuses = statuses
            self.suggestions = suggestions
        }
    }

    public static func reconcile(map: SystemMap, discovered: [DiscoveredThing]) -> Reconciliation {
        var statuses: [String: ComponentStatus] = [:]
        var matched: Set<String> = []

        for component in map.components {
            let match = discovered.first { thing in
                let name = thing.name.lowercased()
                if component.name.lowercased() == name { return true }
                return namesInRuns(component.runs).contains(name)
            }
            if let match {
                statuses[component.name] = .present
                matched.insert(match.name.lowercased())
            } else if component.intended {
                // A plan is not a claim that something exists, so it can never be missing.
                statuses[component.name] = .unchecked
            } else {
                statuses[component.name] = isCheckable(component) ? .missing : .unchecked
            }
        }

        let suggestions = discovered
            .filter { !matched.contains($0.name.lowercased()) }
            .map { MapSuggestion(name: $0.name, kind: kind(forImage: $0.image), detail: $0.detail) }
        return Reconciliation(statuses: statuses, suggestions: suggestions)
    }

    /// A kind proposed from an image name, for something the map does not name yet.
    public static func kind(forImage image: String?) -> ComponentKind {
        guard let image = image?.lowercased() else { return .service }
        // The repository's last path component, without its tag: "ghcr.io/x/redis:7" -> "redis".
        let repository = image.split(separator: "/").last.map(String.init) ?? image
        let name = repository.split(separator: ":").first.map(String.init) ?? repository
        switch name {
        case "postgres", "postgresql", "mysql", "mariadb": return .database
        case "redis", "memcached", "valkey": return .cache
        case "rabbitmq", "nats", "kafka": return .queue
        case "minio": return .storage
        default: return .service
        }
    }

    /// linkC may only report something missing when the map says it runs where linkC looks.
    private static func isCheckable(_ component: SystemComponent) -> Bool {
        let runs = (component.runs ?? "").lowercased()
        return runs.contains("docker") || runs.contains("compose")
    }

    /// The names inside a `runs` text: "docker compose (db)" names "db".
    private static func namesInRuns(_ runs: String?) -> Set<String> {
        guard let runs else { return [] }
        var names: Set<String> = []
        var current = ""
        var depth = 0
        for character in runs {
            switch character {
            case "(", "[":
                depth += 1
                current = ""
            case ")", "]":
                if depth > 0, !current.isEmpty {
                    names.insert(current.trimmingCharacters(in: .whitespaces).lowercased())
                }
                depth = max(0, depth - 1)
                current = ""
            default:
                if depth > 0 { current.append(character) }
            }
        }
        return names
    }
}
