import Foundation

/// A linkC app: a local web app that linkC starts on demand and shows in a project tab. Read
/// from `.linkc/app.json` at the app's root, or built from an app registered in Settings.
public struct LinkCAppManifest: Codable, Equatable, Sendable {
    public var name: String
    /// The command's argv, run with the app's folder as the working folder. Every `{port}` in any
    /// argument becomes the chosen port.
    public var start: [String]
    /// A path that must answer 2xx once the app is ready.
    public var health: String
    /// The page linkC opens.
    public var path: String
    public var env: [String: String]
    /// A preferred port. linkC uses it when it is free, so the page keeps one origin, and with it
    /// its local storage, across starts. Otherwise linkC picks a free port.
    public var port: Int?

    /// The file an app ships at its root.
    public static let relativePath = ".linkc/app.json"

    public init(name: String, start: [String], health: String, path: String = "/", env: [String: String] = [:], port: Int? = nil) {
        self.name = name
        self.start = start
        self.health = health
        self.path = path
        self.env = env
        self.port = port
    }

    /// What one start needs: the argv with every `{port}` replaced, the extra environment, the
    /// health URL and the page URL.
    public struct Launch: Equatable, Sendable {
        public let argv: [String]
        public let environment: [String: String]
        public let healthURL: URL
        public let pageURL: URL
    }

    /// Decodes and validates a manifest. An error names the field that is missing or invalid.
    public static func decode(_ data: Data) throws -> LinkCAppManifest {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.parse("app.json is not valid JSON: \(error.localizedDescription)")
        }
        guard let fields = object as? [String: Any] else { throw LinkCError.parse("app.json must be a JSON object") }
        guard let name = fields["name"] as? String else { throw field("name", "must be a string") }
        guard let start = fields["start"] as? [String] else { throw field("start", "must be a list of strings") }
        guard let health = fields["health"] as? String else { throw field("health", "must be a string") }
        var path = "/"
        if let raw = fields["path"] {
            guard let value = raw as? String else { throw field("path", "must be a string") }
            path = value
        }
        var env: [String: String] = [:]
        if let raw = fields["env"] {
            guard let value = raw as? [String: String] else { throw field("env", "must map strings to strings") }
            env = value
        }
        var port: Int?
        if let raw = fields["port"] {
            guard let value = raw as? Int else { throw field("port", Self.portRule) }
            port = value
        }
        return try LinkCAppManifest(name: name, start: start, health: health, path: path, env: env, port: port).validated()
    }

    public func validated() throws -> LinkCAppManifest {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Self.field("name", "must not be empty") }
        guard let command = start.first, !command.isEmpty else { throw Self.field("start", "must name a command") }
        guard health.hasPrefix("/"), URL(string: "http://127.0.0.1:1" + health) != nil else {
            throw Self.field("health", "must be a URL path that starts with /")
        }
        guard path.hasPrefix("/"), URL(string: "http://127.0.0.1:1" + path) != nil else {
            throw Self.field("path", "must be a URL path that starts with /")
        }
        if let port, !(1024...65535).contains(port) { throw Self.field("port", Self.portRule) }
        return self
    }

    private static let portRule = "must be a whole number from 1024 to 65535"

    public func launch(port: Int) throws -> Launch {
        _ = try validated()
        let portText = String(port)
        let argv = start.map { $0.replacingOccurrences(of: "{port}", with: portText) }
        var environment = env
        environment["LINKC_PORT"] = portText
        let base = "http://127.0.0.1:\(portText)"
        let separator = path.contains("?") ? "&" : "?"
        guard let healthURL = URL(string: base + health), let pageURL = URL(string: base + path + separator + "linkc=1") else {
            throw LinkCError.parse("app.json: the health or page URL for port \(portText) is not valid")
        }
        return Launch(argv: argv, environment: environment, healthURL: healthURL, pageURL: pageURL)
    }

    static func field(_ name: String, _ problem: String) -> LinkCError {
        // No file-path prefix here: a Settings app is built from typed-in strings, not a file —
        // the catalog is the one place that reads an actual `app.json`, and it prefixes with
        // that file's path itself.
        .parse("\"\(name)\" \(problem)")
    }
}
