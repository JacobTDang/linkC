import Foundation

/// Reads and writes a project's `system-map.json`, at the project root rather than inside
/// `.linkc/` — which every repo's `.gitignore` excludes, so a map kept there would never be
/// committed, defeating a feature whose whole point is that any agent, on any machine, can read
/// it. Values in, values out: no caching, no state.
public struct SystemMapStore: Sendable {
    public let fileURL: URL

    public init(workspacePath: String) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace.appendingPathComponent("system-map.json")
    }

    /// The project's map, or nil when it has none. Throws when a file exists but cannot be
    /// read — an unreadable map must never read as an empty system.
    public func load() throws -> SystemMap? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LinkCError.server("could not read \(fileURL.path): \(error.localizedDescription)")
        }
        return try SystemMap.decode(data)
    }

    public func save(_ map: SystemMap) throws {
        let data = try map.encoded()
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw LinkCError.server("could not write \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
