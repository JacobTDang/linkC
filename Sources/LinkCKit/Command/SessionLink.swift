import Foundation

/// `linkc://session/<id>`: a link that opens one session in linkC, as clicking its tab does. Anything
/// outside the app can follow it with `open`, which starts linkC when it isn't running; the
/// linkc-agents mod's cards do.
public enum SessionLink {
    public static let scheme = "linkc"
    private static let host = "session"

    public static func url(for sessionId: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.path = "/\(sessionId)"
        return parts.url!
    }

    /// The session a link names, or nil when it is not a session link.
    public static func sessionId(in url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 1, let id = path.first, !id.isEmpty else { return nil }
        return id
    }
}
