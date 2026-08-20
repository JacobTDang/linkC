import Foundation

/// Services the user asked linkC to watch that it can't discover on its own — a web app
/// on a compute instance, an API behind a domain. Supabase projects need no entry here
/// (their health URL derives from the project ref); this file exists for everything else.
///
/// `<Application Support>/linkC/endpoints.json`:
/// ```json
/// [{"label": "mp3 server", "url": "https://music.example.com/health"}]
/// ```
/// A missing or malformed file means "nothing extra to watch" — never a startup failure.
public struct WatchedEndpointsStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("endpoints.json", isDirectory: false)
    }

    /// The configured endpoints, skipping entries that aren't usable (no label, or a URL
    /// that isn't http/https — a health check must never be turned into a file read).
    public func load() -> [WatchedEndpoint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            NSLog("linkC: endpoints.json at %@ is unreadable, ignoring it", fileURL.path)
            return []
        }
        return entries.enumerated().compactMap { index, entry in
            guard let label = entry.label, !label.isEmpty,
                  let raw = entry.url, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host != nil
            else { return nil }
            // The index keeps ids distinct when two entries share a URL — duplicate
            // Identifiable ids make SwiftUI drop rows, and the monitor's result map would
            // silently discard one of the two probes.
            return WatchedEndpoint(id: "configured:\(index):\(raw)", label: label, url: url)
        }
    }

    public var path: String { fileURL.path }

    /// Create an empty list if the file doesn't exist, so "reveal" has something to
    /// reveal and the user has a file to edit. Writes `[]` rather than a placeholder
    /// entry: a template URL would be probed, fail, and notify about a service that was
    /// never real.
    @discardableResult
    public func ensureExists() -> String {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data("[]\n".utf8).write(to: fileURL, options: .atomic)
            } catch {
                NSLog("linkC: couldn't create %@: %@", fileURL.path, error.localizedDescription)
            }
        }
        return fileURL.path
    }

    private struct Entry: Decodable {
        let label: String?
        let url: String?
    }
}
