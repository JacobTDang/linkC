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
        // Ids key on the URL, not the position: embedding the index would change every
        // id below an inserted line, pruning those services' history and treating the
        // next round as a fresh baseline — so a service that went down across an edit
        // would never be announced. A counter disambiguates genuine duplicates only.
        var seenURLs: [String: Int] = [:]
        return entries.enumerated().compactMap { index, entry in
            guard let label = entry.label, !label.isEmpty,
                  let raw = entry.url, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host != nil
            else {
                // Fail loud: a typo'd entry silently vanishing looks exactly like a
                // service being watched.
                NSLog("linkC: endpoints.json entry %d ignored — needs a label and an "
                      + "http(s) url with a host (got label: %@, url: %@)",
                      index, entry.label ?? "nil", entry.url ?? "nil")
                return nil
            }
            let seen = seenURLs[raw, default: 0]
            seenURLs[raw] = seen + 1
            let id = seen == 0 ? "configured:\(raw)" : "configured:\(raw)#\(seen + 1)"
            return WatchedEndpoint(id: id, label: label, url: url)
        }
    }

    public var path: String { fileURL.path }

    /// Create an empty list if the file doesn't exist, so "reveal" has something to
    /// reveal and the user has a file to edit. Writes `[]` rather than a placeholder
    /// entry: a template URL would be probed, fail, and notify about a service that was
    /// never real.
    /// Throws when the file could not be created — "reveal" must not open Finder on a
    /// path that doesn't exist and leave the user believing it does.
    @discardableResult
    public func ensureExists() throws -> String {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("[]\n".utf8).write(to: fileURL, options: .atomic)
        }
        return fileURL.path
    }

    private struct Entry: Decodable {
        let label: String?
        let url: String?
    }
}
