import Foundation
import Observation

/// One Oracle compute instance, as the sidebar's CLOUD section shows it.
public struct OracleInstance: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let state: String     // RUNNING / STOPPED / STARTING / …

    public var isRunning: Bool { state == "RUNNING" }
}

/// The `~/.oci/config` ini, read section-aware: only the DEFAULT profile's keys count —
/// a `[WORK]` profile listed first must never supply values the CLI (which authenticates
/// as DEFAULT when no --profile is passed) won't be using.
public enum OCIConfig {
    public static func defaultProfileValue(_ key: String, from config: String) -> String? {
        var inDefault = false
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("[") {
                inDefault = trimmed == "[DEFAULT]"
                continue
            }
            guard inDefault else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// The instance parse for `oci search resource structured-search` — one call that spans
/// every compartment in the tenancy (plain `compute instance list` sees only the one
/// compartment it's pointed at, which hides the common child-compartment setup). The
/// `--query` renames fields and drops the rest, keeping output far under the live
/// runner's after-exit 64KB pipe read.
public enum OracleInstances {
    /// The search the service sends; tests pin the CLI contract against these.
    public static let searchText = "query instance resources"
    public static let cliQuery =
        #"data.items[].{id: identifier, name: "display-name", state: "lifecycle-state"}"#

    /// Nil means "this was not the CLI's JSON" — the caller must keep its stale rows
    /// (a banner or wrapper on stdout must never blank the section). A valid empty
    /// listing is `[]`, and that legitimately empties it.
    public static func parse(_ json: String) -> [OracleInstance]? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawInstance].self, from: data) else { return nil }
        return raw.compactMap { entry in
            guard let id = entry.id, let name = entry.name, let state = entry.state,
                  state != "TERMINATED" else { return nil }   // console noise, not state
            return OracleInstance(id: id, name: name, state: state)
        }
    }

    private struct RawInstance: Decodable {
        let id: String?
        let name: String?
        let state: String?
    }
}

/// Oracle compute status through the `oci` CLI. linkC never holds cloud credentials —
/// the CLI owns auth via `~/.oci/config`, the same trust model as docker and claude.
/// Cloud cadence is gentle by design (calls take 1–3s and are rate-limited): callers
/// refresh on panel open plus every ~120s, never the local 15s loop.
@MainActor
@Observable
public final class OracleService {
    public private(set) var instances: [OracleInstance] = []
    public private(set) var isRefreshing = false
    /// The last refresh failure, kept as state (fail loud): expired auth failing every
    /// tick must be inspectable, not a Console.app whisper. Cleared by the next success.
    public private(set) var lastError: String?

    public let ociPath: String?
    /// The DEFAULT profile's region, for the rows' trailing label.
    public let region: String?
    private let hasConfig: Bool
    private let runner: ProcessRunner

    /// Detect the CLI and config from their conventional homes. Either missing → the
    /// service is a permanent quiet no-op and the CLOUD section never renders.
    public convenience init() {
        let path = DockerLocator.resolve(candidates: ["/opt/homebrew/bin/oci", "/usr/local/bin/oci"])
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".oci/config")
        let config = try? String(contentsOf: configURL, encoding: .utf8)
        self.init(
            ociPath: path,
            hasConfig: config != nil,
            region: config.flatMap { OCIConfig.defaultProfileValue("region", from: $0) }
        )
    }

    public init(
        ociPath: String?, hasConfig: Bool, region: String?,
        runner: ProcessRunner = LiveProcessRunner()
    ) {
        self.ociPath = ociPath
        self.hasConfig = hasConfig
        self.region = region
        self.runner = runner
    }

    /// One tenancy-wide instance search. A thrown failure or unparseable output keeps
    /// the stale rows — only a successful, valid listing changes them.
    public func refresh() async {
        guard let ociPath, hasConfig, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await runner.run(
                ociPath,
                args: [
                    "search", "resource", "structured-search",
                    "--query-text", OracleInstances.searchText,
                    "--query", OracleInstances.cliQuery,
                    "--output", "json", "--all",
                ],
                cwd: nil, timeout: Self.listTimeout
            )
            if let parsed = OracleInstances.parse(output) {
                instances = parsed
                lastError = nil
            } else {
                lastError = "oci returned unparseable output (kept the last listing)"
            }
        } catch {
            lastError = "Couldn't list instances: \(error.localizedDescription)"
        }
    }

    private static let listTimeout: TimeInterval = 30
}
