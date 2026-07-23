import Foundation
import Observation

/// The folders sessions and dev terminals were recently launched in — most recent first,
/// deduped by standardized path, capped. Backs the empty state's "Jump back in" chips; the
/// workspace manifest can't (it drops entries on restore/dismiss, so an empty overview has
/// none by definition).
public struct RecentFoldersLog: Codable, Equatable, Sendable {
    public static let cap = 8

    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }

    /// A new log with `path` at the front: standardized (so `/a/b/` and `/a/b` are one
    /// entry), an existing entry moved rather than duplicated, the oldest evicted past
    /// the cap.
    public func recording(_ path: String) -> RecentFoldersLog {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var next = paths.filter { $0 != standardized }
        next.insert(standardized, at: 0)
        return RecentFoldersLog(paths: Array(next.prefix(Self.cap)))
    }
}

/// Persists the log to `<directory>/recents.json` — same IO posture as the workspace
/// manifest: atomic writes, loud NSLog on write failure, a missing or corrupt file
/// tolerated as empty (chips are a convenience; they must never block startup).
@MainActor
@Observable
public final class RecentFoldersStore {
    private let fileURL: URL
    private let directory: URL
    public private(set) var log: RecentFoldersLog

    public var paths: [String] { log.paths }

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("recents.json", isDirectory: false)
        self.log = RecentFoldersStore.load(from: fileURL)
    }

    /// Record a launch folder. Skips the disk write when nothing changed (relaunching in
    /// the same folder you were just in).
    public func record(_ path: String) {
        let next = log.recording(path)
        guard next != log else { return }
        log = next
        save()
    }

    private static func load(from fileURL: URL) -> RecentFoldersLog {
        guard let data = try? Data(contentsOf: fileURL) else { return RecentFoldersLog() }
        do {
            return RecentFoldersLog(paths: try JSONDecoder().decode([String].self, from: data))
        } catch {
            NSLog("linkC: recent folders at %@ are unreadable, treating as empty: %@",
                  fileURL.path, error.localizedDescription)
            return RecentFoldersLog()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(log.paths)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("linkC: failed to write recent folders to %@: %@",
                  fileURL.path, error.localizedDescription)
        }
    }
}
