import Foundation

/// An app the user registered in Settings: its folder and its manifest fields. Available in
/// every project.
public struct LinkCAppSetting: Codable, Equatable, Sendable, Identifiable {
    public var id: String { folder }
    public var folder: String
    public var manifest: LinkCAppManifest

    public init(folder: String, manifest: LinkCAppManifest) {
        self.folder = folder
        self.manifest = manifest
    }
}

/// One app a project can open: where it lives, where it came from, and its manifest, or the
/// reason its manifest can't be used.
public struct LinkCAppEntry: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable { case project, settings }

    public var id: String { folder }
    /// Standardized.
    public let folder: String
    public let source: Source
    /// The manifest's name, or the folder's name when the manifest can't be used.
    public let name: String
    public let manifest: Result<LinkCAppManifest, LinkCError>

    public init(folder: String, source: Source, name: String, manifest: Result<LinkCAppManifest, LinkCError>) {
        self.folder = folder
        self.source = source
        self.name = name
        self.manifest = manifest
    }
}

/// The apps a project can open: the project's own `.linkc/app.json`, then every app registered
/// in Settings. A project app hides a Settings app with the same folder. Each project's manifest
/// is read at most once every `ttl` seconds, because the sidebar and the tab strip ask on every
/// render.
@MainActor
public final class LinkCAppCatalog {
    private let ttl: TimeInterval
    private let now: @MainActor () -> Date
    private var cache: [String: (readAt: Date, entry: LinkCAppEntry?)] = [:]

    public init(ttl: TimeInterval = 2, now: @escaping @MainActor () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    public func apps(inProject path: String, settings: [LinkCAppSetting]) -> [LinkCAppEntry] {
        let folder = (path as NSString).standardizingPath
        let projectApp = projectEntry(folder)
        let settingsApps = settings
            .map { setting -> LinkCAppEntry in
                let settingFolder = (setting.folder as NSString).standardizingPath
                let manifest: Result<LinkCAppManifest, LinkCError>
                do {
                    manifest = .success(try setting.manifest.validated())
                } catch let error as LinkCError {
                    manifest = .failure(error)
                } catch {
                    manifest = .failure(.parse(error.localizedDescription))
                }
                return LinkCAppEntry(folder: settingFolder, source: .settings, name: setting.manifest.name, manifest: manifest)
            }
            .filter { $0.folder != projectApp?.folder }
        return (projectApp.map { [$0] } ?? []) + settingsApps
    }

    private func projectEntry(_ folder: String) -> LinkCAppEntry? {
        if let cached = cache[folder], now().timeIntervalSince(cached.readAt) < ttl { return cached.entry }
        let entry = Self.readProjectEntry(folder)
        cache[folder] = (now(), entry)
        return entry
    }

    private static func readProjectEntry(_ folder: String) -> LinkCAppEntry? {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(LinkCAppManifest.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest: Result<LinkCAppManifest, LinkCError>
        do {
            manifest = .success(try LinkCAppManifest.decode(Data(contentsOf: url)))
        } catch let error as LinkCError {
            manifest = .failure(error)
        } catch {
            manifest = .failure(.parse("\(url.path) could not be read: \(error.localizedDescription)"))
        }
        let name = (try? manifest.get().name) ?? URL(fileURLWithPath: folder).lastPathComponent
        return LinkCAppEntry(folder: folder, source: .project, name: name, manifest: manifest)
    }
}
