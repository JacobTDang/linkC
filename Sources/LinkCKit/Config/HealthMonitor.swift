import Foundation
import Network
import Observation

/// What one probe learned. A service that ANSWERS is alive — even a 401: verified against
/// the live Supabase API, where an unauthenticated health call returns 401 in ~0.2s while
/// a paused project doesn't resolve at all. Only 5xx (answering but broken) and no answer
/// at all are bad news.
public enum HealthStatus: Equatable, Sendable {
    /// Not checked, or checked from a machine that had no working network — an honest
    /// absence of knowledge, never reported as an outage.
    case unknown
    case ok(Int, TimeInterval)
    case degraded(Int, TimeInterval)
    case down(String)

    public static func classify(code: Int, latency: TimeInterval) -> HealthStatus {
        code >= 500 ? .degraded(code, latency) : .ok(code, latency)
    }

    /// Failures that could equally be this machine's network or the service's: DNS,
    /// timeouts, refused connections. Individually they're real outages — but when EVERY
    /// watched service hits one in the same round, a captive portal, VPN flip, DNS
    /// outage, or wake-from-sleep is far likelier than every provider dying at once.
    static func isConnectivityFailure(_ error: Error) -> Bool {
        if isLocalNetworkFailure(error) { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed, .timedOut, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    /// True when the error means the probe never left this machine.
    static func isLocalNetworkFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cancelled,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            // DNS failure, refused connection, TLS failure and timeouts are all things
            // the service itself did (or failed to do) — those stay real outages.
            return false
        }
    }

    /// Which of the four states this is, ignoring the code and latency inside it. What
    /// counts as a CHANGE — and therefore what has to be confirmed before it is recorded —
    /// is a move between kinds; drifting from 120ms to 900ms is the same news.
    enum Kind { case unknown, ok, degraded, down }

    var kind: Kind {
        switch self {
        case .unknown: return .unknown
        case .ok: return .ok
        case .degraded: return .degraded
        case .down: return .down
        }
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

/// Does this machine have a working network path at all? The honest answer to "is the
/// service down, or am I?" — inferring it from "every probe failed" cannot tell a dead
/// Wi-Fi from the one host that happens to run every watched service.
public protocol NetworkReachability: Sendable {
    var isOnline: Bool { get }
}

public final class LiveNetworkReachability: NetworkReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true   // optimistic until the monitor says otherwise

    public init() {
        // weak: the monitor is owned by self and its handler outlives every update, so a
        // strong capture would keep this object alive forever — and `deinit`, the only
        // thing that cancels the monitor, would never run.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            online = path.status == .satisfied
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "linkc.reachability"))
    }

    deinit { monitor.cancel() }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }
}

/// The seam every health check goes through — faked in tests, URLSession in the app.
public protocol EndpointProbe: Sendable {
    func probe(_ url: URL, timeout: TimeInterval) async throws -> ProbeResult
}

public struct LiveEndpointProbe: EndpointProbe {
    public init() {}

    public func probe(_ url: URL, timeout: TimeInterval) async throws -> ProbeResult {
        // HEAD first: a watched endpoint may be a whole page, and downloading it every
        // 30s to throw it away is waste. Verified live that Supabase's auth health answers
        // HEAD with the same 401 it gives GET. Servers that refuse the method get a GET.
        let head = try await send(url, method: "HEAD", timeout: timeout)
        // Retry ONLY when the status says the METHOD was refused. Retrying every 4xx
        // defeated the optimisation for the headline case (Supabase answers 401, so every
        // probe made two requests) — and worse, a HEAD that proved the host is alive could
        // be overwritten by a transient GET failure and reported as an outage.
        guard Self.methodRejections.contains(head.statusCode) else { return head }
        do {
            return try await send(url, method: "GET", timeout: timeout)
        } catch {
            // HEAD already demonstrated the host answers; a flaky retry doesn't unprove it.
            return head
        }
    }

    /// 405 Method Not Allowed and 501 Not Implemented are the ONLY codes that mean the
    /// method was refused. 400/403 are answers about the request or its auth — retrying
    /// those defeated the optimisation and let a worse GET status replace a HEAD that had
    /// already proven the host answers.
    private static let methodRejections: Set<Int> = [405, 501]

    private func send(_ url: URL, method: String, timeout: TimeInterval) async throws -> ProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Monotonic: the wall clock can be stepped by NTP mid-probe — likely right after
        // wake, which is exactly when the panel reopens and a check fires — and that would
        // render a nonsense or negative round-trip.
        let started = DispatchTime.now().uptimeNanoseconds
        let (_, response) = try await Self.session.data(for: request)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProbeResult(statusCode: http.statusCode, latency: Double(elapsed) / 1_000_000_000)
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

/// How much a cached project listing can be trusted to say what is worth probing.
///
/// The Supabase watch list is derived from `supabase projects list`, and `healthURL` is an
/// ALLOWLIST over that listing's status. So the allowlist is only ever as fresh as the
/// listing: a free project that auto-paused hours ago still reads ACTIVE_HEALTHY in a
/// stale snapshot, stops resolving, and gets reported as an outage — the exact false alarm
/// the allowlist was written to prevent.
public struct ListingFreshness: Sendable {
    /// How old a listing may get before the beat re-lists. Well above the beat interval:
    /// re-listing spawns a CLI, and doing that every minute forever to catch a status that
    /// changes maybe twice a month is not a trade worth making.
    public let refreshInterval: TimeInterval
    /// How old a listing may get before it stops driving ALERTS. Reached only when
    /// refreshing has failed repeatedly (expired auth, no network) — the rows stay on
    /// screen, they just stop being grounds to claim a service died.
    public let trustWindow: TimeInterval

    public init(refreshInterval: TimeInterval, trustWindow: TimeInterval) {
        self.refreshInterval = refreshInterval
        self.trustWindow = trustWindow
    }

    public static let standard = ListingFreshness(refreshInterval: 300, trustWindow: 1800)

    public func shouldRefresh(lastListedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastListedAt else { return true }
        return now.timeIntervalSince(lastListedAt) >= refreshInterval
    }

    public func isTrustworthy(lastListedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastListedAt else { return false }
        return now.timeIntervalSince(lastListedAt) < trustWindow
    }
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
    private let reachability: NetworkReachability
    private var isChecking = false
    /// A kind seen since the recorded status, and how many rounds in a row it has held.
    private var pending: [String: (kind: HealthStatus.Kind, count: Int)] = [:]
    private let confirmations: Int

    /// - Parameter confirmations: how many consecutive rounds a new kind must hold before
    ///   it is recorded. Two is the smallest number that survives a single flap; one would
    ///   restore the every-beat notification storm this exists to stop.
    public init(
        probe: EndpointProbe = LiveEndpointProbe(),
        reachability: NetworkReachability = LiveNetworkReachability(),
        confirmations: Int = 2
    ) {
        self.probe = probe
        self.reachability = reachability
        self.confirmations = max(1, confirmations)
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
        let readings = await withTaskGroup(of: Reading.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do {
                        let result = try await probe.probe(endpoint.url, timeout: timeout)
                        return Reading(
                            id: endpoint.id,
                            status: .classify(code: result.statusCode, latency: result.latency),
                            connectivityFailure: false
                        )
                    } catch {
                        // A failure on OUR side (Wi-Fi off, laptop asleep, VPN flip) says
                        // nothing about the service. Calling it down would alert that
                        // every watched service died at once, then "recovered" together —
                        // the alarm fatigue the transition rules exist to prevent. nil
                        // means "no reading": the previous one stands, so a real outage
                        // arriving right after a blip is still announced against what we
                        // last actually knew.
                        let connectivity = HealthStatus.isConnectivityFailure(error)
                        if HealthStatus.isLocalNetworkFailure(error) {
                            return Reading(id: endpoint.id, status: nil, connectivityFailure: true)
                        }
                        return Reading(
                            id: endpoint.id,
                            status: .down(error.localizedDescription),
                            connectivityFailure: connectivity
                        )
                    }
                }
            }
            var collected: [Reading] = []
            for await reading in group { collected.append(reading) }
            return collected
        }

        // If this machine had no network path, the round says nothing about the services.
        // This asks the OS rather than inferring it from "everything failed" — that guess
        // could not tell a dead Wi-Fi from the one host running every watched service, and
        // would have suppressed such an outage forever.
        if !reachability.isOnline, readings.contains(where: \.connectivityFailure) {
            return []
        }

        var results: [String: HealthStatus] = [:]
        for reading in readings {
            // A round with no reading (a local blip) leaves the pending count alone: it is
            // an absence of evidence, not evidence of recovery, so it must not postpone a
            // real outage by resetting the count every time the link stutters.
            guard let status = reading.status else { continue }
            if let confirmed = confirmed(reading.id, status) { results[reading.id] = confirmed }
        }

        let changes = HealthTransitions.changes(from: statuses, to: results, endpoints: endpoints)
        // Keep readings for endpoints that weren't in this round (nothing observed is not
        // the same as observed-as-down), then drop anything no longer watched. Pruning
        // here — inside the round that actually ran — means a re-entrant call dropped by
        // the guard above can't prune against its own stale list.
        statuses.merge(results) { _, new in new }
        let live = Set(endpoints.map(\.id))
        statuses = statuses.filter { live.contains($0.key) }
        pending = pending.filter { live.contains($0.key) }
        return changes
    }

    /// Damping. A service sitting on the timeout boundary alternates pass/fail every beat,
    /// and reporting each flip is louder than any sustained outage — the transition rules
    /// only quieten an outage that STAYS down. So a change of kind must hold for
    /// `confirmations` rounds before it becomes the recorded status; until then the last
    /// confirmed reading stands and nothing is announced. Recovery is confirmed the same
    /// way, or the noise would simply move to the "back up" side.
    ///
    /// Returns the status to record, or nil to leave the previous one in place.
    private func confirmed(_ id: String, _ status: HealthStatus) -> HealthStatus? {
        let kind = status.kind
        // Nothing recorded yet: the first reading is a baseline, which announces nothing
        // and is what the UI has to show. There is no change to confirm.
        guard let current = statuses[id] else {
            pending[id] = nil
            return status
        }
        // Same kind — latency drift, a different 5xx code — is not a change; record it live
        // so the row stays honest between beats.
        if current.kind == kind {
            pending[id] = nil
            return status
        }
        let streak = (pending[id]?.kind == kind ? pending[id]!.count : 0) + 1
        guard streak >= confirmations else {
            pending[id] = (kind, streak)
            return nil
        }
        pending[id] = nil
        return status
    }

    private struct Reading: Sendable {
        let id: String
        let status: HealthStatus?
        let connectivityFailure: Bool
    }

    /// Forget endpoints that are no longer watched, so a removed service can't leave a
    /// stale status behind.
    public func prune(to endpoints: [WatchedEndpoint]) {
        let live = Set(endpoints.map(\.id))
        statuses = statuses.filter { live.contains($0.key) }
        pending = pending.filter { live.contains($0.key) }
    }
}
