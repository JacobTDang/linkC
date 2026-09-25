import Foundation

public enum BoardMapStoreError: Error, Equatable {
    /// The file no longer holds what linkC last read — something else changed it.
    case changedOnDisk
}

/// Reads and writes a project's `system-map.json` at its root. It remembers nothing: the caller
/// keeps the bytes it read and hands them back, so a change made underneath it is never overwritten.
public struct BoardMapStore: Sendable {
    public let fileURL: URL

    public struct Loaded: Sendable {
        public let map: BoardMap
        /// Exactly what was on disk — what the next save must still find there.
        public let bytes: Data
    }

    public init(workspacePath: String) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace.appendingPathComponent("system-map.json")
    }

    /// A detail board's store: `system-map.<slug>.json` beside the overview. nil is the overview.
    public init(workspacePath: String, board slug: String?) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace.appendingPathComponent(BoardSlug.fileName(for: slug))
    }

    /// The project's map, or nil when it has none. Throws when a file exists but cannot be read.
    public func load() throws -> Loaded? {
        guard let bytes = try currentBytes() else { return nil }
        return Loaded(map: try BoardMap.decode(bytes), bytes: bytes)
    }

    /// Writes `map` only if the file still holds `expected` — or is still absent when `expected`
    /// is nil. Returns the bytes written, which become the next save's `expected`.
    public func save(_ map: BoardMap, expecting expected: Data?) throws -> Data {
        guard try currentBytes() == expected else { throw BoardMapStoreError.changedOnDisk }
        let data = try map.encoded()
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw LinkCError.server("could not write \(fileURL.path): \(error.localizedDescription)")
        }
        return data
    }

    /// The file's exact bytes, undecoded — what a caller compares against before deciding whether
    /// a decode is even worth doing.
    public func currentBytes() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw LinkCError.server("could not read \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
