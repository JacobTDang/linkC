import Foundation
import Observation

/// What one probe learned. A service that ANSWERS is alive — even a 401: verified against
/// the live Supabase API, where an unauthenticated health call returns 401 in ~0.2s while
/// a paused project doesn't resolve at all. Only 5xx (answering but broken) and no answer
/// at all are bad news.
public enum HealthStatus: Equatable, Sendable {
    case unknown
    case ok(Int, TimeInterval)
    case degraded(Int, TimeInterval)
    case down(String)

    public static func classify(code: Int, latency: TimeInterval) -> HealthStatus {
        code >= 500 ? .degraded(code, latency) : .ok(code, latency)
    }

    public var isUp: Bool {
        if case .ok = self { return true }
        return false
    }

    /// One glanceable token for a dense row: the round trip when healthy, the status code
    /// when the server is erroring, "down" when nothing answered.
    public var shortLabel: String {
        switch self {
        case .unknown: return "—"
        case .ok(_, let latency): return "\(Int((latency * 1000).rounded()))ms"
        case .degraded(let code, _): return "\(code)"
        case .down: return "down"
        }
    }
}

/// One thing worth watching: a Supabase project (URL derived from its ref) or a service
/// the user named in the endpoints file.
public struct WatchedEndpoint: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let url: URL

    public init(id: String, label: String, url: URL) {
        self.id = id
        self.label = label
        self.url = url
    }
}

public struct ProbeResult: Equatable, Sendable {
    public let statusCode: Int
    public let latency: TimeInterval

    public init(statusCode: Int, latency: TimeInterval) {
        self.statusCode = statusCode
        self.latency = latency
    }
}

/// The seam every health check goes through — faked in tests, URLSession in the app.
public protocol EndpointProbe: Sendable {
    func probe(_ url: URL, timeout: TimeInterval) async throws -> ProbeResult
}

public struct LiveEndpointProbe: EndpointProbe {
    public init() {}

    public func probe(_ url: URL, timeout: TimeInterval) async throws -> ProbeResult {
        var request = URLRequest(url: url)
        // GET, not HEAD: some services (Supabase's auth health among them) answer HEAD
        // differently or not at all, and the body is discarded anyway.
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let started = Date()
        let (_, response) = try await Self.session.data(for: request)
        let latency = Date().timeIntervalSince(started)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProbeResult(statusCode: http.statusCode, latency: latency)
    }

    /// An ephemeral session: health checks must never be answered from cache, and no
    /// cookie or credential state should accumulate for services we only ping.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
}

/// A status change worth telling the user about.
public struct HealthChange: Equatable, Sendable {
    public let endpointId: String
    public let title: String
    public let body: String
}

/// Which changes deserve a notification. The rule that matters: alert on CHANGE, never on
/// repetition — an outage that has lasted an hour must not re-alert every 30 seconds, and
/// the first observation of anything is a baseline rather than news.
public enum HealthTransitions {
    public static func changes(
        from previous: [String: HealthStatus],
        to current: [String: HealthStatus],
        endpoints: [WatchedEndpoint]
    ) -> [HealthChange] {
        endpoints.compactMap { endpoint in
            guard let now = current[endpoint.id] else { return nil }
            // No prior reading (or an explicit unknown) means this is the baseline.
            guard let before = previous[endpoint.id], before != .unknown else { return nil }
            // Same-kind moves (ok→ok latency drift, down→down with a different reason)
            // fall to `default` and stay silent — that switch, not an equality check, is
            // what prevents alarm fatigue.
            switch (before, now) {
            case (.ok, .down), (.degraded, .down):
                return HealthChange(
                    endpointId: endpoint.id,
                    title: endpoint.label,
                    body: "\(endpoint.label) is not responding"
                )
            case (.ok, .degraded(let code, _)), (.down, .degraded(let code, _)):
                return HealthChange(
                    endpointId: endpoint.id,
                    title: endpoint.label,
                    body: "\(endpoint.label) is answering \(code)"
                )
            case (.down, .ok), (.degraded, .ok):
                return HealthChange(
                    endpointId: endpoint.id,
                    title: endpoint.label,
                    body: "\(endpoint.label) is back up"
                )
            default:
                // ok → ok (latency drift) and any other same-kind move: not an event.
                return nil
            }
        }
    }
}

/// Probes watched endpoints and remembers what it found. Checks run only while the panel
/// is visible (the caller's cadence), and every endpoint is probed concurrently so one
/// slow host doesn't delay the rest.
@MainActor
@Observable
public final class HealthMonitor {
    public private(set) var statuses: [String: HealthStatus] = [:]

    private let probe: EndpointProbe
    private var isChecking = false

    public init(probe: EndpointProbe = LiveEndpointProbe()) {
        self.probe = probe
    }

    public func status(of id: String) -> HealthStatus? { statuses[id] }

    /// Probe everything and return the changes worth announcing. Re-entrant calls are
    /// dropped: a slow round must not stack up behind the 30s timer.
    @discardableResult
    public func check(_ endpoints: [WatchedEndpoint], timeout: TimeInterval = 8) async -> [HealthChange] {
        guard !isChecking, !endpoints.isEmpty else { return [] }
        isChecking = true
        defer { isChecking = false }

        let probe = self.probe
        let results = await withTaskGroup(of: (String, HealthStatus).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do {
                        let result = try await probe.probe(endpoint.url, timeout: timeout)
                        return (endpoint.id, .classify(code: result.statusCode, latency: result.latency))
                    } catch {
                        return (endpoint.id, .down(error.localizedDescription))
                    }
                }
            }
            var collected: [String: HealthStatus] = [:]
            for await (id, status) in group { collected[id] = status }
            return collected
        }

        let changes = HealthTransitions.changes(from: statuses, to: results, endpoints: endpoints)
        // Keep readings for endpoints that weren't in this round (nothing observed is not
        // the same as observed-as-down).
        statuses.merge(results) { _, new in new }
        return changes
    }

    /// Forget endpoints that are no longer watched, so a removed service can't leave a
    /// stale status behind.
    public func prune(to endpoints: [WatchedEndpoint]) {
        let live = Set(endpoints.map(\.id))
        statuses = statuses.filter { live.contains($0.key) }
    }
}
