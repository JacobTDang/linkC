import Foundation

/// One installed plugin, as reported by `claude plugin list --json` — the authoritative
/// source for scope, enablement, and (deduped, non-orphaned) install paths.
public struct InstalledPlugin: Equatable, Sendable, Identifiable, Decodable {
    public let id: String            // "name@marketplace"
    public let version: String
    public let scope: String         // "user" | "project" | "local"
    public let enabled: Bool
    public let installPath: String
    public let projectPath: String?

    public init(id: String, version: String, scope: String, enabled: Bool,
                installPath: String, projectPath: String?) {
        self.id = id
        self.version = version
        self.scope = scope
        self.enabled = enabled
        self.installPath = installPath
        self.projectPath = projectPath
    }

    /// The plugin's bare name (before "@") — the prefix `skillUsage` keys use.
    public var bareName: String {
        String(id.split(separator: "@").first ?? "")
    }
}

public enum PluginList {
    public static func parse(_ jsonData: Data) throws -> [InstalledPlugin] {
        try JSONDecoder().decode([InstalledPlugin].self, from: jsonData)
    }
}
