import Foundation
import Observation

/// One Oracle compute instance, as the sidebar's CLOUD section shows it.
public struct OracleInstance: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let state: String     // RUNNING / STOPPED / STARTING / …
    public let shape: String
    public let region: String

    public var isRunning: Bool { state == "RUNNING" }
}

/// The `~/.oci/config` tenancy parse — the compartment every instance listing needs.
public enum OCIConfig {
    /// First uncommented `tenancy=` line wins; nil when the key is absent.
    public static func tenancy(from config: String) -> String? {
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "tenancy" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// The instance-list parse. The CLI is invoked with a JMESPath `--query` that renames
/// fields and drops the rest — the full listing runs kilobytes per instance, and the
/// live runner reads stdout only after exit (64KB pipe ceiling).
public enum OracleInstances {
    /// The exact --query the service sends; tests pin the contract against it.
    public static let cliQuery =
        #"data[].{id: id, name: "display-name", state: "lifecycle-state", shape: shape, region: region}"#

    public static func parse(_ json: String) -> [OracleInstance] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawInstance].self, from: data) else { return [] }
        return raw.compactMap { entry in
            guard let id = entry.id, let name = entry.name, let state = entry.state,
                  state != "TERMINATED" else { return nil }   // console noise, not state
            return OracleInstance(
                id: id, name: name, state: state,
                shape: entry.shape ?? "", region: entry.region ?? ""
            )
        }
    }

    private struct RawInstance: Decodable {
        let id: String?
        let name: String?
        let state: String?
        let shape: String?
        let region: String?
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

    public let ociPath: String?
    private let tenancy: String?
    private let runner: ProcessRunner

    /// Detect the CLI and tenancy from their conventional homes. Either missing → the
    /// service is a permanent quiet no-op and the CLOUD section never renders.
    public convenience init() {
        let path = ["/opt/homebrew/bin/oci", "/usr/local/bin/oci"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".oci/config")
        let tenancy = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap(OCIConfig.tenancy(from:))
        self.init(ociPath: path, tenancy: tenancy)
    }

    public init(ociPath: String?, tenancy: String?, runner: ProcessRunner = LiveProcessRunner()) {
        self.ociPath = ociPath
        self.tenancy = tenancy
        self.runner = runner
    }

    /// One instance listing. Failures keep the stale rows — a network blip must not
    /// blank the section; rows only change when a successful call says so.
    public func refresh() async {
        guard let ociPath, let tenancy, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await runner.run(
                ociPath,
                args: [
                    "compute", "instance", "list",
                    "--compartment-id", tenancy,
                    "--query", OracleInstances.cliQuery,
                    "--output", "json",
                ],
                cwd: nil, timeout: Self.listTimeout
            )
            instances = OracleInstances.parse(output)
        } catch {
            NSLog("linkC: oci instance list failed (keeping stale rows): %@", error.localizedDescription)
        }
    }

    private static let listTimeout: TimeInterval = 30
}
