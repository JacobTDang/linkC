import Foundation
import Observation

/// One Supabase project, as the sidebar's CLOUD section shows it.
public struct SupabaseProject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let region: String
    /// ACTIVE_HEALTHY / INACTIVE / COMING_UP / …
    public let status: String
    /// Shown in the drill-in beside uptime.
    public var postgresVersion: String?
    public var createdAt: Date?

    public var isHealthy: Bool { status == "ACTIVE_HEALTHY" }

    /// The credential-free liveness endpoint, derived from the project ref — no
    /// configuration needed. Verified live: an active project answers 401 in ~0.2s (proof
    /// the API is up), so any answer counts as alive.
    ///
    /// Only a project the control plane calls healthy is probed. This is an ALLOWLIST on
    /// purpose: PAUSING, RESTORING, REMOVED, INIT_FAILED and friends don't resolve or
    /// refuse, so "not INACTIVE" would fire a false "not responding" alert for exactly
    /// the transitional states the row already names.
    public var healthURL: URL? {
        guard isHealthy else { return nil }
        return URL(string: "https://\(id).supabase.co/auth/v1/health")
    }
    public var isPaused: Bool { Self.isPaused(status) }

    /// Supabase pauses free projects after inactivity — they stop serving requests until
    /// restored, which is the one status worth calling out on a glance row.
    public static func isPaused(_ status: String) -> Bool { status == "INACTIVE" }
}

/// `supabase projects list --output json`. The CLI prints unrelated notices (e.g.
/// "Cannot find project ref") to stderr, which the runner folds into thrown errors rather
/// than into stdout — but the parser tolerates a leading banner anyway.
public enum SupabaseProjects {
    /// Nil for unparseable output (the caller keeps its stale rows); `[]` only for a
    /// genuinely empty account.
    public static func parse(_ output: String) -> [SupabaseProject]? {
        guard let raw = decodeArray(output) else { return nil }
        return raw.compactMap { entry in
            guard let id = entry.id, let name = entry.name else { return nil }
            return SupabaseProject(
                id: id,
                name: name,
                region: entry.region ?? "",
                status: entry.status ?? "UNKNOWN",
                postgresVersion: entry.database?.postgresEngine,
                createdAt: entry.createdAt.flatMap(TranscriptLine.parseTimestamp)
            )
        }
    }

    /// Try each `[` in turn: a notice can contain a bracket (an ANSI escape, a `[warn]`
    /// prefix), and slicing from the first one would start mid-banner and fail.
    private static func decodeArray(_ output: String) -> [RawProject]? {
        var searchStart = output.startIndex
        while let bracket = output[searchStart...].firstIndex(of: "[") {
            if let data = String(output[bracket...]).data(using: .utf8),
               let raw = try? JSONDecoder().decode([RawProject].self, from: data) {
                return raw
            }
            searchStart = output.index(after: bracket)
            if searchStart >= output.endIndex { break }
        }
        return nil
    }

    private struct RawProject: Decodable {
        let id: String?
        let name: String?
        let region: String?
        let status: String?
        let database: RawDatabase?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, region, status, database
            case createdAt = "created_at"
        }
    }

    private struct RawDatabase: Decodable {
        let postgresEngine: String?
        enum CodingKeys: String, CodingKey { case postgresEngine = "postgres_engine" }
    }
}

/// Supabase projects through the user's own `supabase` CLI — the second CLOUD provider,
/// built on the same contract as Oracle: linkC never holds credentials (the CLI keeps its
/// token in the macOS Keychain via `supabase login`), calls are gentle, and a failure
/// keeps the last known rows rather than blanking the section.
@MainActor
@Observable
public final class SupabaseService {
    public private(set) var projects: [SupabaseProject] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?
    /// When the last SUCCESSFUL listing landed. The health beat re-lists off this, and
    /// refuses to raise outage alerts from a listing too old to mean anything — the
    /// `healthURL` allowlist can only be as fresh as the statuses it filters on.
    public private(set) var lastListedAt: Date?
    /// True when the CLI reports no access token. That's the expected first-run state, not
    /// an error — the UI can invite `supabase login` instead of crying failure.
    public private(set) var needsLogin = false

    public let cliPath: String?
    private let runner: ProcessRunner

    public convenience init() {
        self.init(cliPath: DockerLocator.resolve(
            candidates: ["/opt/homebrew/bin/supabase", "/usr/local/bin/supabase"]
        ))
    }

    public init(cliPath: String?, runner: ProcessRunner = LiveProcessRunner()) {
        self.cliPath = cliPath
        self.runner = runner
    }

    /// Re-list only when the last listing has aged past `freshness.refreshInterval`. The
    /// health beat runs every minute; spawning a CLI that often, forever, to catch a status
    /// that changes maybe twice a month is not a trade worth making — but never re-listing
    /// leaves every derived endpoint as stale as the first snapshot.
    public func refreshIfStale(
        _ freshness: ListingFreshness = .standard, now: Date = Date()
    ) async {
        guard cliPath != nil,
              freshness.shouldRefresh(lastListedAt: lastListedAt, now: now) else { return }
        await refresh()
    }

    public func refresh() async {
        guard let cliPath, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await runner.run(
                cliPath, args: ["projects", "list", "--output", "json"],
                cwd: nil, timeout: Self.listTimeout
            )
            if let parsed = SupabaseProjects.parse(output) {
                projects = parsed
                lastListedAt = Date()
                lastError = nil
                needsLogin = false
            } else {
                lastError = "supabase returned unreadable output (kept the last listing)"
            }
        } catch {
            // "Not logged in" is a state with an obvious next step, not a failure to shout
            // about; anything else is a real error.
            let message = error.localizedDescription
            if message.contains("Access token not provided") || message.contains("supabase login") {
                needsLogin = true
                lastError = nil
            } else {
                needsLogin = false
                lastError = "Couldn't list Supabase projects: \(message)"
            }
        }
    }

    private static let listTimeout: TimeInterval = 30
}
