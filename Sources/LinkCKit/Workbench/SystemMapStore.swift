import Foundation

/// Reads and writes a project's `.linkc/system.json`, beside the blackboard and handoff files
/// linkC already keeps there. Values in, values out: no caching, no state.
public struct SystemMapStore: Sendable {
    public let fileURL: URL

    public init(workspacePath: String) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace
            .appendingPathComponent(".linkc", isDirectory: true)
            .appendingPathComponent("system.json")
    }

    /// The project's map, or nil when it has none. Throws when a file exists but cannot be
    /// read — an unreadable map must never read as an empty system.
    public func load() throws -> SystemMap? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LinkCError.parse("could not read \(fileURL.path): \(error.localizedDescription)")
        }
        return try SystemMap.decode(data)
    }

    public func save(_ map: SystemMap) throws {
        let data = try map.encoded()
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw LinkCError.process("could not write \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
