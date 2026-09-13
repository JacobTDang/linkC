import Foundation

/// Reads Codex's own quota state straight from its session rollouts — the file Codex writes
/// its exact rate-limit snapshot to on every turn, rather than the terminal text linkC used to
/// scrape (and once misread as exhaustion). `rate_limits` sits nested under a line's `payload`
/// (never at the top level) in every real rollout this was checked against.
public struct CodexUsageReader: Sendable {
    private let sessionsDirectory: URL

    /// Codex's limits are account-wide, so only the newest few sessions need checking —
    /// whichever wrote most recently carries the authoritative snapshot.
    private static let maxFilesToCheck = 5
    /// Only the trailing slice of a rollout is read: the rate-limit record is emitted on
    /// every turn, so it's always near the end of an active or recently-active file.
    private static let tailCapBytes = 64 * 1024
    private static let fiveHourMinutes = 300
    private static let sevenDayMinutes = 10080

    public init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    public func read() -> AgentUsage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return unavailable("no ~/.codex/sessions directory")
        }

        let files = rolloutFiles()
        guard !files.isEmpty else {
            return unavailable("no session records found")
        }

        for (url, modified) in files {
            switch scan(url) {
            case .found(let rateLimits):
                return usage(from: rateLimits, observedAt: modified)
            case .malformed:
                return unavailable("rate-limit record could not be read")
            case .notFound:
                continue
            }
        }
        return unavailable("no rate-limit record in the \(Self.maxFilesToCheck) newest sessions")
    }

    // MARK: - File discovery

    private func rolloutFiles() -> [(url: URL, modified: Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var results: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            results.append((url, modified))
        }
        return results
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxFilesToCheck)
            .map { (url: $0.0, modified: $0.1) }
    }

    // MARK: - Scanning one file

    private enum ScanResult {
        case found(RateLimits)
        case malformed
        case notFound
    }

    /// Scans a file's tail from the end for the first line whose JSON carries `rate_limits`.
    /// A line that names `rate_limits` but fails to decode into the expected shape is reported
    /// as malformed rather than silently skipped to an older, possibly-stale record.
    private func scan(_ url: URL) -> ScanResult {
        guard let lines = Self.tailLines(of: url) else { return .notFound }
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let envelope = try? Self.decoder.decode(Envelope.self, from: data),
                  let rateLimits = envelope.payload?.rateLimits
            else {
                NSLog("linkC: codex rate-limit record at %@ could not be read", url.path)
                return .malformed
            }
            return .found(rateLimits)
        }
        return .notFound
    }

    /// Reads only the trailing `tailCapBytes` of `url` and returns its complete lines, dropping
    /// a leading fragment when the seek landed mid-line (mirrors `TranscriptTailReader`'s
    /// first-read boundary handling, applied here as a one-shot read with no offset to track).
    private static func tailLines(of url: URL) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let start = size > UInt64(tailCapBytes) ? size - UInt64(tailCapBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd()
        else { return nil }

        // Skip through the first newline BYTE, in the raw Data, before ever decoding: the
        // seek may have landed mid multi-byte UTF-8 character, and a newline byte (0x0A) can
        // never occur inside one, so everything after it is guaranteed to start on a
        // character boundary. Decoding the raw cut buffer first would fail the whole buffer
        // on a single split character — reading as "no record" and falling through to an
        // older, stale file instead of the one that actually has the newest record.
        if start > 0, data.first != 0x0A {
            guard let firstNewline = data.firstIndex(of: 0x0A) else { return [] }
            data = data[data.index(after: firstNewline)...]
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Mapping

    private func usage(from rateLimits: RateLimits, observedAt: Date) -> AgentUsage {
        var windows: [UsageWindow] = []
        if let primary = rateLimits.primary {
            windows.append(UsageWindow(
                label: Self.label(forMinutes: primary.windowMinutes),
                usedPercent: primary.usedPercent,
                tokens: nil,
                resetsAt: Date(timeIntervalSince1970: primary.resetsAt)
            ))
        }
        if let secondary = rateLimits.secondary {
            windows.append(UsageWindow(
                label: Self.label(forMinutes: secondary.windowMinutes),
                usedPercent: secondary.usedPercent,
                tokens: nil,
                resetsAt: Date(timeIntervalSince1970: secondary.resetsAt)
            ))
        }
        return AgentUsage(
            agent: .codex,
            windows: windows,
            planType: rateLimits.planType,
            observedAt: observedAt,
            unavailableReason: nil
        )
    }

    private static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case fiveHourMinutes: return "5h"
        case sevenDayMinutes: return "7d"
        default: return "\(minutes)m"
        }
    }

    private func unavailable(_ reason: String) -> AgentUsage {
        AgentUsage(agent: .codex, windows: [], planType: nil, observedAt: nil, unavailableReason: reason)
    }

    // MARK: - Wire shapes

    private static let decoder = JSONDecoder()

    private struct Envelope: Decodable {
        let payload: Payload?

        struct Payload: Decodable {
            let rateLimits: RateLimits?

            enum CodingKeys: String, CodingKey {
                case rateLimits = "rate_limits"
            }
        }
    }

    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case primary, secondary
            case planType = "plan_type"
        }

        struct Window: Decodable {
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Double

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }
        }
    }
}
