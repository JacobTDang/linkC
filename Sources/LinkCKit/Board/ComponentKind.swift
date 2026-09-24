import Foundation

/// What a component is. The known values drive the tile's glyph; any other value is kept
/// verbatim and drawn plainly, so a kind linkC has not learned yet never breaks a file.
public struct ComponentKind: Equatable, Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    // MARK: - System

    public static let database = ComponentKind("database")
    public static let cache = ComponentKind("cache")
    public static let queue = ComponentKind("queue")
    public static let storage = ComponentKind("storage")
    public static let service = ComponentKind("service")
    public static let host = ComponentKind("host")
    public static let external = ComponentKind("external")

    // MARK: - AI agents

    public static let agent = ComponentKind("agent")
    public static let model = ComponentKind("model")
    public static let tool = ComponentKind("tool")
    public static let mcp = ComponentKind("mcp")
    public static let router = ComponentKind("router")
    public static let start = ComponentKind("start")
    public static let end = ComponentKind("end")
    public static let vectorStore = ComponentKind("vector-store")
    public static let memory = ComponentKind("memory")
    public static let prompt = ComponentKind("prompt")
    public static let state = ComponentKind("state")
    public static let human = ComponentKind("human")

    // MARK: - Hardware

    public static let alu = ComponentKind("alu")
    public static let mux = ComponentKind("mux")
    public static let demux = ComponentKind("demux")
    public static let register = ComponentKind("register")
    public static let ram = ComponentKind("ram")
    public static let control = ComponentKind("control")
    public static let adder = ComponentKind("adder")
    public static let decoder = ComponentKind("decoder")
    public static let clock = ComponentKind("clock")
    public static let bus = ComponentKind("bus")

    /// One named, ordered group of kinds, for the toolbar's Component menu.
    public struct Group: Sendable {
        public let title: String
        public let kinds: [ComponentKind]
    }

    public static let groups: [Group] = [
        Group(title: "System", kinds: [.database, .cache, .queue, .storage, .service, .host, .external]),
        Group(
            title: "AI agents",
            kinds: [.agent, .model, .tool, .mcp, .router, .start, .end, .vectorStore, .memory, .prompt, .state, .human]),
        Group(
            title: "Hardware",
            kinds: [.alu, .mux, .demux, .register, .ram, .control, .adder, .decoder, .clock, .bus]),
    ]

    /// Every kind linkC knows, in group order — the flat union of `groups`.
    public static let known: [ComponentKind] = groups.flatMap(\.kinds)

    public var isKnown: Bool { Self.known.contains(self) }

    /// `groups`, rendered as "System: …; AI agents: …; Hardware: …" for tool descriptions and the
    /// `linkc_get_board` footer, so an agent can always discover every kind linkC knows.
    public static var groupedKindList: String {
        groups.map { group in "\(group.title): \(group.kinds.map(\.raw).joined(separator: ", "))" }.joined(separator: "; ")
    }
}
