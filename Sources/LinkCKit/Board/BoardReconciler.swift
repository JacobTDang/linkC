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
public enum BoardReconciler {
    public struct Reconciliation: Equatable, Sendable {
        public let statuses: [String: ComponentStatus]
        public let suggestions: [MapSuggestion]

        public init(statuses: [String: ComponentStatus], suggestions: [MapSuggestion]) {
            self.statuses = statuses
            self.suggestions = suggestions
        }
    }

    public static func reconcile(map: BoardMap, discovered: [DiscoveredThing]) -> Reconciliation {
        var statuses: [String: ComponentStatus] = [:]
        // Discovered names already backing a component, so one running thing cannot back two —
        // the map's own component order decides who claims it first.
        var claimed: Set<String> = []
        let componentNames = Set(map.components.map { $0.name.lowercased() })

        for component in map.components {
            let match = discovered.first { thing in
                let name = thing.name.lowercased()
                guard !claimed.contains(name) else { return false }
                if component.name.lowercased() == name { return true }
                return namesInRuns(component.runs).contains(name)
            }
            if let match {
                statuses[component.name] = .present
                claimed.insert(match.name.lowercased())
            } else if component.planned {
                // A plan is not a claim that something exists, so it can never be missing.
                statuses[component.name] = .unchecked
            } else {
                statuses[component.name] = isCheckable(component) ? .missing : .unchecked
            }
        }

        // Never suggest something already claimed, and never suggest a name the map already
        // carries — even when that component was matched through its `runs` text instead.
        let suggestions = discovered
            .filter { !claimed.contains($0.name.lowercased()) && !componentNames.contains($0.name.lowercased()) }
            .map { MapSuggestion(name: $0.name, kind: kind(forImage: $0.image), detail: $0.detail) }
        return Reconciliation(statuses: statuses, suggestions: suggestions)
    }

    /// A kind proposed from an image name, for something the map does not name yet.
    public static func kind(forImage image: String?) -> ComponentKind {
        guard let image = image?.lowercased(), !image.isEmpty else { return .service }
        // A digest pin sits after "@" and is never part of the repository name:
        // "redis@sha256:9f2..." -> "redis", "redis:7@sha256:9f2..." -> "redis:7".
        let withoutDigest = image.split(separator: "@", maxSplits: 1).first.map(String.init) ?? image
        // The repository's last path component, without its tag: "ghcr.io/x/redis:7" -> "redis".
        let repository = withoutDigest.split(separator: "/").last.map(String.init) ?? withoutDigest
        let name = repository.split(separator: ":").first.map(String.init) ?? repository
        switch name {
        case "postgres", "postgresql", "mysql", "mariadb": return .database
        case "redis", "memcached", "valkey": return .cache
        case "rabbitmq", "nats", "kafka": return .queue
        case "minio": return .storage
        default: return .service
        }
    }

    /// linkC may only report something missing when the map says it runs where linkC looks —
    /// in its own `runs` text, or in the label of the frame it lives in.
    private static func isCheckable(_ component: BoardComponent) -> Bool {
        let evidence = "\(component.runs ?? "") \(component.place)".lowercased()
        return evidence.contains("docker") || evidence.contains("compose")
    }

    /// The names inside a `runs` text: "docker compose (db)" names "db", and a parenthetical
    /// naming several things, comma-separated, names each of them: "docker compose (api, worker)"
    /// names "api" and "worker", not the combined "api, worker".
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
                    for piece in current.split(separator: ",") {
                        let trimmed = piece.trimmingCharacters(in: .whitespaces).lowercased()
                        if !trimmed.isEmpty { names.insert(trimmed) }
                    }
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
