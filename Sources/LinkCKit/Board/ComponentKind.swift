import Foundation

/// What a component is. The known values drive the tile's glyph; any other value is kept
/// verbatim and drawn plainly, so a kind linkC has not learned yet never breaks a file.
public struct ComponentKind: Equatable, Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static let database = ComponentKind("database")
    public static let cache = ComponentKind("cache")
    public static let queue = ComponentKind("queue")
    public static let storage = ComponentKind("storage")
    public static let service = ComponentKind("service")
    public static let host = ComponentKind("host")
    public static let external = ComponentKind("external")

    public static let known: [ComponentKind] = [
        .database, .cache, .queue, .storage, .service, .host, .external,
    ]

    public var isKnown: Bool { Self.known.contains(self) }
}
