import Foundation

/// A container's drill-in overview from `docker inspect`. Env VALUES are discarded at parse
/// time — container env routinely carries secrets, so only key names exist in memory (the
/// same structural redaction as MCP headers).
public struct ContainerDetail: Equatable, Sendable {
    public let image: String
    public let status: String
    public let startedAt: Date?
    public let restartCount: Int
    public let ports: [String]      // "3002/tcp → 127.0.0.1:3002"
    public let mounts: [String]     // "volume → /var/fdb"
    public let envKeys: [String]    // sorted key names, never values
}

public enum DockerInspect {
    public static func parse(_ data: Data) -> ContainerDetail? {
        guard let entries = try? JSONDecoder().decode([RawInspect].self, from: data),
              let raw = entries.first else { return nil }

        let ports = (raw.networkSettings?.ports ?? [:])
            .compactMap { containerPort, bindings -> String? in
                guard let bindings, !bindings.isEmpty else { return nil }
                let hosts = bindings.map { "\($0.hostIp ?? "0.0.0.0"):\($0.hostPort ?? "?")" }
                return "\(containerPort) → \(hosts.joined(separator: ", "))"
            }
            .sorted()

        return ContainerDetail(
            image: raw.config?.image ?? "",
            status: raw.state?.status ?? "unknown",
            startedAt: raw.state?.startedAt.flatMap(parseTimestamp),
            restartCount: raw.restartCount ?? 0,
            ports: ports,
            mounts: (raw.mounts ?? []).map { "\($0.type ?? "bind") → \($0.destination ?? "?")" },
            // "KEY=value" → KEY; the value never crosses this line.
            envKeys: (raw.config?.env ?? [])
                .compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
                .sorted()
        )
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    private struct RawInspect: Decodable {
        let restartCount: Int?
        let state: RawState?
        let config: RawConfig?
        let mounts: [RawMount]?
        let networkSettings: RawNetwork?

        enum CodingKeys: String, CodingKey {
            case restartCount = "RestartCount"
            case state = "State"
            case config = "Config"
            case mounts = "Mounts"
            case networkSettings = "NetworkSettings"
        }
    }

    private struct RawState: Decodable {
        let status: String?
        let startedAt: String?
        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case startedAt = "StartedAt"
        }
    }

    private struct RawConfig: Decodable {
        let image: String?
        let env: [String]?
        enum CodingKeys: String, CodingKey {
            case image = "Image"
            case env = "Env"
        }
    }

    private struct RawMount: Decodable {
        let type: String?
        let destination: String?
        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case destination = "Destination"
        }
    }

    private struct RawNetwork: Decodable {
        let ports: [String: [RawBinding]?]?
        enum CodingKeys: String, CodingKey { case ports = "Ports" }
    }

    private struct RawBinding: Decodable {
        let hostIp: String?
        let hostPort: String?
        enum CodingKeys: String, CodingKey {
            case hostIp = "HostIp"
            case hostPort = "HostPort"
        }
    }
}

/// One-shot resource figures from `docker stats --no-stream --format json` — docker's own
/// formatted strings, passed through untouched.
public struct ContainerStats: Equatable, Sendable {
    public let cpu: String
    public let memory: String

    /// Numeric CPU for sorting and thresholds — "188.85%" → 188.85; unparseable → 0.
    public var cpuValue: Double {
        Double(cpu.replacingOccurrences(of: "%", with: "")) ?? 0
    }
}

public enum DockerStats {
    public static func parse(_ line: String) -> ContainerStats? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawStats.self, from: data),
              let cpu = raw.cpuPerc, let memory = raw.memUsage else { return nil }
        return ContainerStats(cpu: cpu, memory: memory)
    }

    /// The batch sweep: every running container's one-shot figures keyed by container id,
    /// one JSON line each. Garbage lines are skipped alone.
    public static func parseAll(_ output: String) -> [String: ContainerStats] {
        var byId: [String: ContainerStats] = [:]
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawStats.self, from: data),
                  let id = raw.id, let cpu = raw.cpuPerc, let memory = raw.memUsage
            else { continue }
            byId[id] = ContainerStats(cpu: cpu, memory: memory)
        }
        return byId
    }

    private struct RawStats: Decodable {
        let id: String?
        let cpuPerc: String?
        let memUsage: String?
        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case cpuPerc = "CPUPerc"
            case memUsage = "MemUsage"
        }
    }
}

/// One image from `docker images --format json`. Dangling layers report `<none>` as their
/// repository — prune's only targets.
public struct ImageInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let repository: String
    public let tag: String
    public let size: String
    public let createdSince: String

    public var isDangling: Bool { repository == "<none>" }
    public var reference: String { isDangling ? id : "\(repository):\(tag)" }
}

public enum DockerImages {
    public static func parse(_ output: String) -> [ImageInfo] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawImage.self, from: data),
                  let id = raw.id else { return nil }
            return ImageInfo(
                id: id,
                repository: raw.repository ?? "<none>",
                tag: raw.tag ?? "<none>",
                size: raw.size ?? "",
                createdSince: raw.createdSince ?? ""
            )
        }
    }

    private struct RawImage: Decodable {
        let id: String?
        let repository: String?
        let tag: String?
        let size: String?
        let createdSince: String?
        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case repository = "Repository"
            case tag = "Tag"
            case size = "Size"
            case createdSince = "CreatedSince"
        }
    }
}
