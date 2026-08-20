import Foundation
import Observation

/// One Oracle compute instance, as the sidebar's CLOUD section shows it.
public struct OracleInstance: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let state: String     // RUNNING / STOPPED / STARTING / …
    /// When the instance was created — the row's "up 17d" figure. (OCI reports creation,
    /// not last boot; a reboot doesn't reset it, so the label says "up" loosely.)
    public var createdAt: Date?

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
        #"data.items[].{id: identifier, name: "display-name", state: "lifecycle-state", created: "time-created"}"#

    /// Nil means "this was not the CLI's JSON" — the caller must keep its stale rows
    /// (a banner or wrapper on stdout must never blank the section). A valid empty
    /// listing is `[]`, and that legitimately empties it.
    public static func parse(_ json: String) -> [OracleInstance]? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawInstance].self, from: data) else { return nil }
        return raw.compactMap { entry in
            guard let id = entry.id, let name = entry.name, let state = entry.state,
                  state != "TERMINATED" else { return nil }   // console noise, not state
            return OracleInstance(
                id: id, name: name, state: state,
                createdAt: entry.created.flatMap(TranscriptLine.parseTimestamp)
            )
        }
    }

    private struct RawInstance: Decodable {
        let id: String?
        let name: String?
        let state: String?
        let created: String?
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
    /// The drill-in's own failures. Separate from `lastError` so a successful expand can't
    /// erase a listing failure (expired auth must stay inspectable) and vice versa.
    public private(set) var detailError: String?
    /// Drill-in results, cached per instance for the panel session — expanding a row
    /// twice reuses what's here rather than re-hitting a rate-limited API.
    public private(set) var details: [String: OracleDetail] = [:]
    private var inFlightDetails: Set<String> = []

    public let ociPath: String?
    /// The DEFAULT profile's region, for the rows' trailing label.
    public let region: String?
    /// The DEFAULT profile's tenancy OCID — the monitoring API requires a compartment.
    private let tenancy: String?
    private let hasConfig: Bool
    private let runner: ProcessRunner
    /// Principals that are expected on this account — anything else in the audit trail is
    /// worth flagging. Seeded from the config's user OCID owner where available.
    private let knownPrincipals: Set<String>

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
            region: config.flatMap { OCIConfig.defaultProfileValue("region", from: $0) },
            tenancy: config.flatMap { OCIConfig.defaultProfileValue("tenancy", from: $0) }
        )
    }

    public init(
        ociPath: String?, hasConfig: Bool, region: String?, tenancy: String? = nil,
        knownPrincipals: Set<String> = [],
        runner: ProcessRunner = LiveProcessRunner()
    ) {
        self.ociPath = ociPath
        self.hasConfig = hasConfig
        self.region = region
        self.tenancy = tenancy
        self.runner = runner
        self.knownPrincipals = knownPrincipals
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
                    "--output", "json",
                ],
                cwd: nil, timeout: Self.listTimeout
            )
            if let parsed = OracleInstances.parse(output) {
                instances = parsed
                pruneDetails()
                lastError = nil
            } else {
                lastError = "oci returned unparseable output (kept the last listing)"
            }
        } catch {
            lastError = "Couldn't list instances: \(error.localizedDescription)"
        }
    }

    /// The cached drill-in for an instance, if it has been expanded.
    public func detail(for id: String) -> OracleDetail? { details[id] }

    /// Fetch one instance's drill-in: public IP and latest CPU mean. On-demand only —
    /// never on the polling path. `force` is the row's refresh action; without it a cached
    /// detail is reused (the API is rate-limited and these figures move slowly).
    /// The metrics call is tenancy-wide, so its whole map is stored — expanding a second
    /// row reuses it instead of issuing an identical call.
    public func loadDetail(for id: String, force: Bool = false) async {
        guard let ociPath, hasConfig else { return }
        // A row seeded by the metrics fan-out has CPU but no IP — it still needs its own
        // VNIC call, so only a genuinely loaded row counts as cached.
        guard force || details[id]?.didLoadIP != true else { return }
        guard !inFlightDetails.contains(id) else { return }   // no last-writer-wins races
        inFlightDetails.insert(id)
        defer { inFlightDetails.remove(id) }

        let runner = self.runner
        let tenancy = self.tenancy
        // Both calls run concurrently; each reports its own failure so one hiccup can't
        // hide the other's answer.
        async let vnicsOutput: String? = {
            do {
                return try await runner.run(
                    ociPath,
                    args: ["compute", "instance", "list-vnics", "--instance-id", id,
                           "--query", OracleVnics.cliQuery, "--output", "json"],
                    cwd: nil, timeout: Self.listTimeout
                )
            } catch {
                return nil
            }
        }()
        // One call per metric, concurrently — see healthMetrics for why not one joined call.
        async let metricOutputs: [String] = {
            guard let tenancy else { return [] }
            return await withTaskGroup(of: String?.self) { group in
                for metric in OracleMetrics.healthMetrics {
                    group.addTask {
                        try? await runner.run(
                            ociPath,
                            args: ["monitoring", "metric-data", "summarize-metrics-data",
                                   "--compartment-id", tenancy,
                                   "--compartment-id-in-subtree", "true",
                                   "--namespace", "oci_computeagent",
                                   "--query-text", OracleMetrics.healthQueryText(metric),
                                   "--query", OracleMetrics.healthQuery, "--output", "json"],
                            cwd: nil, timeout: Self.listTimeout
                        )
                    }
                }
                var outputs: [String] = []
                for await output in group {
                    if let output { outputs.append(output) }
                }
                return outputs
            }
        }()
        // The security half: who touched the account in the last 24h.
        async let auditOutput: String? = {
            guard let tenancy else { return nil }
            let end = Date()
            let start = end.addingTimeInterval(-24 * 3600)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            do {
                return try await runner.run(
                    ociPath,
                    args: ["audit", "event", "list",
                           "--compartment-id", tenancy,
                           "--start-time", formatter.string(from: start),
                           "--end-time", formatter.string(from: end),
                           "--output", "json"],
                    cwd: nil, timeout: Self.listTimeout
                )
            } catch {
                return nil
            }
        }()

        var failures: [String] = []
        // Distinguish "the call failed" from "this instance has no public IP" — a
        // private-only box is a legitimate state, and coalescing over it would strand a
        // stale address on screen forever.
        let vnicsResult = await vnicsOutput
        let vnicsFailed = vnicsResult == nil
        let ip = vnicsResult.flatMap(OracleVnics.publicIP)
        if vnicsFailed { failures.append("IP unavailable") }

        var healthByInstance: [String: OracleHealth] = [:]
        let outputs = await metricOutputs
        // Each call contributes its own metric; a partial set is better than none.
        for output in outputs {
            for (instanceId, health) in OracleMetrics.healthByInstance(output) {
                var merged = healthByInstance[instanceId] ?? OracleHealth()
                merged.cpuPercent = health.cpuPercent ?? merged.cpuPercent
                merged.memoryPercent = health.memoryPercent ?? merged.memoryPercent
                merged.loadAverage = health.loadAverage ?? merged.loadAverage
                healthByInstance[instanceId] = merged
            }
        }
        let metricsFailed = outputs.isEmpty
        if metricsFailed {
            failures.append(tenancy == nil ? "metrics: no tenancy in ~/.oci/config" : "metrics unavailable")
        }

        // The audit summary is account-wide, so it applies to every row equally.
        var auditSummary: OracleAuditSummary?
        if let output = await auditOutput {
            auditSummary = OracleAudit.summarize(output, knownPrincipals: knownPrincipals)
            if auditSummary == nil { failures.append("audit unreadable") }
        } else if tenancy != nil {
            failures.append("audit unavailable")
        }

        // One tenancy-wide metrics call serves every row — keep the whole map, not just
        // this instance's slice.
        for (instanceId, health) in healthByInstance where instanceId != id {
            let existing = details[instanceId]
            details[instanceId] = OracleDetail(
                publicIP: existing?.publicIP,
                cpuPercent: health.cpuPercent,
                memoryPercent: health.memoryPercent,
                loadAverage: health.loadAverage,
                audit: auditSummary ?? existing?.audit,
                didLoadIP: existing?.didLoadIP ?? false   // metrics alone is not a loaded row
            )
        }
        // Fields degrade independently: a failed metrics call keeps the last known CPU
        // rather than replacing a real figure with "—".
        // Keep the last known value only when the call FAILED; a successful call that
        // reports nothing is the truth (the IP really was unassigned).
        let previous = details[id]
        let health = healthByInstance[id]
        details[id] = OracleDetail(
            publicIP: vnicsFailed ? previous?.publicIP : ip,
            cpuPercent: metricsFailed ? previous?.cpuPercent : health?.cpuPercent,
            memoryPercent: metricsFailed ? previous?.memoryPercent : health?.memoryPercent,
            loadAverage: metricsFailed ? previous?.loadAverage : health?.loadAverage,
            audit: auditSummary ?? previous?.audit,
            didLoadIP: true
        )
        // Fail loud: a swallowed drill-in error is indistinguishable from "no public IP".
        detailError = failures.isEmpty ? nil : "Couldn't load details — \(failures.joined(separator: "; "))"
    }

    /// Drop cached drill-ins for instances that are no longer listed — a stopped-and-
    /// restarted box must not keep showing its old IP.
    private func pruneDetails() {
        let live = Set(instances.map(\.id))
        details = details.filter { live.contains($0.key) }
    }

    private static let listTimeout: TimeInterval = 30
}

/// What a drill-in shows for one instance. Fields degrade independently — a metrics
/// hiccup must not hide the IP, and neither must collapse the row.
public struct OracleDetail: Equatable, Sendable {
    public let publicIP: String?
    public let cpuPercent: Double?
    public var memoryPercent: Double? = nil
    public var loadAverage: Double? = nil
    /// Recent account activity — the "is it still mine?" half.
    public var audit: OracleAuditSummary? = nil
    /// True once this row's own VNIC call has been attempted. A row seeded only by the
    /// tenancy-wide metrics fan-out is NOT loaded — without this it would look cached and
    /// never fetch its IP.
    public var didLoadIP: Bool = false
}

/// `oci compute instance list-vnics --query 'data[].{...}'` — the public IP, when the
/// instance has one (private-only boxes legitimately don't).
public enum OracleVnics {
    public static let cliQuery = #"data[].{"public-ip": "public-ip", "private-ip": "private-ip"}"#

    public static func publicIP(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([RawVnic].self, from: data) else { return nil }
        return rows.compactMap(\.publicIP).first { !$0.isEmpty }
    }

    private struct RawVnic: Decodable {
        let publicIP: String?
        enum CodingKeys: String, CodingKey { case publicIP = "public-ip" }
    }
}

/// One instance's health figures, from a single multi-metric monitoring call.
public struct OracleHealth: Equatable, Sendable {
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var loadAverage: Double?
}

/// The audit trail's answer to "is it still mine?" — how much happened, who did it, and
/// whether anyone unfamiliar appears. `system` principals are OCI's own automation, not
/// people, so they're counted but never listed.
public struct OracleAuditSummary: Equatable, Sendable {
    public let eventCount: Int
    public let humanPrincipals: [String]
    public let hasUnknownPrincipal: Bool
}

public enum OracleAudit {
    /// `oci audit event list` emits MULTIPLE concatenated JSON documents (one per page) —
    /// verified against the live CLI, where a plain decode fails with "Extra data". Each
    /// document is decoded in turn and their events concatenated.
    public static func summarize(_ output: String, knownPrincipals: Set<String> = []) -> OracleAuditSummary? {
        let documents = splitDocuments(output)
        guard !documents.isEmpty else { return nil }
        var count = 0
        var people: Set<String> = []
        for document in documents {
            guard let data = document.data(using: .utf8),
                  let page = try? JSONDecoder().decode(RawPage.self, from: data) else { continue }
            let events = page.data ?? []
            count += events.count
            for event in events {
                guard let name = event.data?.identity?.principalName, !name.isEmpty else { continue }
                people.insert(name)
            }
        }
        let unknown = knownPrincipals.isEmpty ? false : !people.subtracting(knownPrincipals).isEmpty
        return OracleAuditSummary(
            eventCount: count, humanPrincipals: people.sorted(), hasUnknownPrincipal: unknown
        )
    }

    /// Split concatenated top-level JSON objects by brace depth (string-aware).
    private static func splitDocuments(_ output: String) -> [String] {
        var documents: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in output.indices {
            let character = output[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let from = start {
                    documents.append(String(output[from...index]))
                    start = nil
                }
            default: break
            }
        }
        return documents
    }

    private struct RawPage: Decodable { let data: [RawEvent]? }
    private struct RawEvent: Decodable { let data: RawEventData? }
    private struct RawEventData: Decodable { let identity: RawIdentity? }
    private struct RawIdentity: Decodable {
        let principalName: String?
        enum CodingKeys: String, CodingKey { case principalName = "principal-name" }
    }
}

/// `oci monitoring metric-data summarize-metrics-data` — CPU means keyed by the
/// `resourceId` dimension, so one tenancy-wide call covers every instance. The newest
/// datapoint wins; a series with no datapoints contributes nothing (never a bogus zero).
public enum OracleMetrics {
    public static let cliQuery =
        #"data[].{dimensions: dimensions, "aggregated-datapoints": "aggregated-datapoints"}"#
    public static let queryText = "CpuUtilization[1h].mean()"
    /// One metric per call. `||`-joined MQL looks tempting but OCI JOINS the series into
    /// one named `join-#<id>`, losing the per-metric name entirely — verified against the
    /// live API. Three concurrent calls cost the same wall-clock and keep the names.
    public static let healthMetrics = ["CpuUtilization", "MemoryUtilization", "LoadAverage"]
    public static func healthQueryText(_ metric: String) -> String { "\(metric)[1h].mean()" }
    public static let healthQuery =
        #"data[].{name: name, dimensions: dimensions, "aggregated-datapoints": "aggregated-datapoints"}"#

    /// Health figures per instance from a multi-metric response — split by the series'
    /// `name` and its `resourceId` dimension. A metric absent for a box stays nil rather
    /// than reading as a confident zero.
    public static func healthByInstance(_ json: String) -> [String: OracleHealth] {
        guard let data = json.data(using: .utf8),
              let series = try? JSONDecoder().decode([RawSeries].self, from: data) else { return [:] }
        var byId: [String: OracleHealth] = [:]
        for entry in series {
            guard let id = entry.dimensions?.resourceId,
                  let value = latestValue(entry.datapoints) else { continue }
            var health = byId[id] ?? OracleHealth()
            switch entry.name {
            case "CpuUtilization": health.cpuPercent = value
            case "MemoryUtilization": health.memoryPercent = value
            case "LoadAverage": health.loadAverage = value
            default: break
            }
            byId[id] = health
        }
        return byId
    }

    private static func latestValue(_ points: [RawPoint]?) -> Double? {
        points?
            .compactMap { point -> (Date, Double)? in
                guard let stamp = point.timestamp.flatMap(TranscriptLine.parseTimestamp),
                      let value = point.value else { return nil }
                return (stamp, value)
            }
            .max(by: { $0.0 < $1.0 })?.1
    }

    public static func latestCpuByInstance(_ json: String) -> [String: Double] {
        guard let data = json.data(using: .utf8),
              let series = try? JSONDecoder().decode([RawSeries].self, from: data) else { return [:] }
        var byId: [String: Double] = [:]
        for entry in series {
            guard let id = entry.dimensions?.resourceId,
                  let latest = entry.datapoints?
                    .compactMap({ point -> (Date, Double)? in
                        guard let stamp = point.timestamp.flatMap(TranscriptLine.parseTimestamp),
                              let value = point.value else { return nil }
                        return (stamp, value)
                    })
                    .max(by: { $0.0 < $1.0 })
            else { continue }
            byId[id] = latest.1
        }
        return byId
    }

    private struct RawSeries: Decodable {
        let name: String?
        let dimensions: RawDimensions?
        let datapoints: [RawPoint]?
        enum CodingKeys: String, CodingKey {
            case name, dimensions
            case datapoints = "aggregated-datapoints"
        }
    }

    private struct RawDimensions: Decodable {
        let resourceId: String?
    }

    private struct RawPoint: Decodable {
        let timestamp: String?
        let value: Double?
    }
}
