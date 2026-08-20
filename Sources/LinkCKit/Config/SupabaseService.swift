import Foundation
import Observation

/// One Supabase project, as the sidebar's CLOUD section shows it.
public struct SupabaseProject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let region: String
    /// ACTIVE_HEALTHY / INACTIVE / COMING_UP / …
    public let status: String
    public let postgresVersion: String?

    public var isHealthy: Bool { status == "ACTIVE_HEALTHY" }
    public var isPaused: Bool { Self.isPaused(status) }

    /// Supabase pauses free projects after inactivity — they stop serving requests until
    /// restored, which is the one status worth calling out on a glance row.
    public static func isPaused(_ status: String) -> Bool { status == "INACTIVE" }
}

/// `supabase projects list --output json`. The CLI can print unrelated notices (e.g.
/// "Cannot find project ref") — those go to stderr, which the live runner discards, but
/// the parser tolerates a leading banner anyway rather than trusting that forever.
public enum SupabaseProjects {
    /// Nil for unparseable output (the caller keeps its stale rows); `[]` only for a
    /// genuinely empty account.
    public static func parse(_ output: String) -> [SupabaseProject]? {
        guard let start = output.firstIndex(of: "["),
              let data = String(output[start...]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawProject].self, from: data) else { return nil }
        return raw.compactMap { entry in
            guard let id = entry.id, let name = entry.name else { return nil }
            return SupabaseProject(
                id: id,
                name: name,
                region: entry.region ?? "",
                status: entry.status ?? "UNKNOWN",
                postgresVersion: entry.database?.postgresEngine
            )
        }
    }

    private struct RawProject: Decodable {
        let id: String?
        let name: String?
        let region: String?
        let status: String?
        let database: RawDatabase?
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
