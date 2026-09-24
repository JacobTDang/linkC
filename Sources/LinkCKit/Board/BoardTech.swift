import Foundation

/// A catalog entry: what a component's shape draws when it carries this technology.
public struct BoardTechInfo: Equatable, Sendable {
    public let id: String            // canonical id, e.g. "postgresql"
    public let displayName: String   // "PostgreSQL"
    public let svg: String           // 24×24 SVG, brand-coloured
    public let isDark: Bool          // brand colour too dark for the dark board: the app tints it
}

/// The catalog of technology logos a Board component can carry, and how a component finds its
/// own: its explicit `tech`, or else an exact match on its name. Agent names (`claude`, `codex`,
/// `cursor`, `antigravity`/`agy`) are handled separately by `agent(for:)` — `resolve` never
/// returns them, since the app draws `AgentLogoView` for those instead.
public enum BoardTech {
    /// (id, displayName, aliases) — the source of truth for `canonical`, `knownIDs` and `info`.
    /// The id is Simple Icons' slug; logos themselves live in the generated `BoardTechLogos.swift`.
    private static let table: [(id: String, displayName: String, aliases: [String])] = [
        ("postgresql", "PostgreSQL", ["postgres", "pg"]),
        ("mysql", "MySQL", []),
        ("mariadb", "MariaDB", []),
        ("sqlite", "SQLite", []),
        ("mongodb", "MongoDB", ["mongo"]),
        ("redis", "Redis", []),
        ("rabbitmq", "RabbitMQ", []),
        ("apachekafka", "Kafka", ["kafka"]),
        ("docker", "Docker", []),
        ("kubernetes", "Kubernetes", ["k8s"]),
        ("nginx", "nginx", []),
        ("nodedotjs", "Node.js", ["node", "nodejs"]),
        ("python", "Python", []),
        ("go", "Go", ["golang"]),
        ("rust", "Rust", []),
        ("swift", "Swift", []),
        ("deno", "Deno", []),
        ("bun", "Bun", []),
        ("supabase", "Supabase", []),
        ("firebase", "Firebase", []),
        ("vercel", "Vercel", []),
        ("cloudflare", "Cloudflare", []),
        ("stripe", "Stripe", []),
        ("github", "GitHub", []),
        ("googlecloud", "Google Cloud", ["gcp"]),
        ("digitalocean", "DigitalOcean", []),
        ("elasticsearch", "Elasticsearch", []),
        ("graphql", "GraphQL", []),
        ("prisma", "Prisma", []),
        ("nextdotjs", "Next.js", ["next", "nextjs"]),
        ("react", "React", []),
        ("fastapi", "FastAPI", []),
        ("django", "Django", []),
        ("rubyonrails", "Rails", ["rails"]),
        ("spring", "Spring", []),
        ("minio", "MinIO", []),
        ("clickhouse", "ClickHouse", []),
        ("neo4j", "Neo4j", []),
        ("sentry", "Sentry", []),
        ("grafana", "Grafana", []),
        ("prometheus", "Prometheus", []),
        ("auth0", "Auth0", []),
        ("resend", "Resend", []),
        ("netlify", "Netlify", []),
        ("flydotio", "Fly.io", ["fly"]),
        ("railway", "Railway", []),
        ("render", "Render", []),
    ]

    /// Every canonical id, sorted — for the tool description.
    public static let knownIDs: [String] = table.map(\.id).sorted()

    /// id or alias (case-insensitive) → canonical id, built once from `table`.
    private static let aliasLookup: [String: String] = {
        var map: [String: String] = [:]
        for entry in table {
            map[entry.id.lowercased()] = entry.id
            for alias in entry.aliases {
                map[alias.lowercased()] = entry.id
            }
        }
        return map
    }()

    /// Canonical id → its info, built once. Every id in `table` must have an embedded logo —
    /// a missing one is a generator bug, not something to hide behind an optional.
    private static let infoByID: [String: BoardTechInfo] = {
        var map: [String: BoardTechInfo] = [:]
        for entry in table {
            guard let logo = logos[entry.id] else {
                fatalError("BoardTech: no embedded logo for known id \"\(entry.id)\"")
            }
            map[entry.id] = BoardTechInfo(id: entry.id, displayName: entry.displayName, svg: logo.svg, isDark: logo.isDark)
        }
        return map
    }()

    /// A canonical id for an id or alias, case-insensitively; nil when unknown.
    public static func canonical(_ raw: String) -> String? {
        aliasLookup[raw.lowercased()]
    }

    public static func info(_ id: String) -> BoardTechInfo? {
        infoByID[id]
    }

    private static let agentNames: [String: AgentKind] = [
        "claude": .claude,
        "codex": .codex,
        "cursor": .cursor,
        "antigravity": .agy,
        "agy": .agy,
    ]

    /// `component.tech`, or nil when it is unset or empty — "no tech" either way, for inference
    /// from the name to fall back to.
    private static func explicitTech(_ component: BoardComponent) -> String? {
        guard let tech = component.tech, !tech.isEmpty else { return nil }
        return tech
    }

    /// An agent's logo for a component named like an agent (claude, codex, cursor, antigravity, agy).
    /// A tech overrides the name: inference from the name — agent names included — applies only
    /// when `tech` is nil or empty; an explicit `tech` that names no agent means no agent logo,
    /// never a fall back to the name. `agent(for:)` is what the app checks first, before `resolve`.
    public static func agent(for component: BoardComponent) -> AgentKind? {
        if let tech = explicitTech(component) {
            return agentNames[tech.lowercased()]
        }
        return agentNames[component.name.lowercased()]
    }

    /// What a component is drawn with: its `tech` when known, else an exact (case-insensitive)
    /// name match to a known id or alias — only once `tech` is nil or empty. Never writes
    /// anything. Agent names resolve to nil here; callers check `agent(for:)` first.
    public static func resolve(_ component: BoardComponent) -> BoardTechInfo? {
        guard agent(for: component) == nil else { return nil }
        if let tech = explicitTech(component) {
            return canonical(tech).flatMap(info)
        }
        return canonical(component.name).flatMap(info)
    }
}
