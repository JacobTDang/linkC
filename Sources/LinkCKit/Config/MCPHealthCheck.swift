import Foundation

/// One server's live status as reported by `claude mcp list`. The target string is whatever
/// claude printed — already secret-free (it never prints headers or env).
public struct MCPHealthStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case connected
        case needsAuth
        case failed(String)
        case unknown(String)
    }

    public let name: String
    public let target: String
    public let isHTTP: Bool
    public let state: State
}

/// Parses `claude mcp list` stdout. Line shape (verified against real output):
/// `<name>: <target> [(HTTP)] - <✔|!|✗> <status text>` — names can contain spaces, targets
/// contain colons, so the split points are the LAST " - " and the FIRST ": ".
public enum MCPHealthCheck {
    public static func parse(_ output: String) -> [MCPHealthStatus] {
        output.split(separator: "\n").compactMap { line in
            parseLine(String(line))
        }
    }

    private static func parseLine(_ line: String) -> MCPHealthStatus? {
        guard
            let statusSplit = line.range(of: " - ", options: .backwards),
            let nameSplit = line.range(of: ": ")
        else { return nil }
        guard nameSplit.lowerBound < statusSplit.lowerBound else { return nil }

        let name = String(line[..<nameSplit.lowerBound]).trimmingCharacters(in: .whitespaces)
        var target = String(line[nameSplit.upperBound..<statusSplit.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var isHTTP = false
        if target.hasSuffix("(HTTP)") {
            isHTTP = true
            target = String(target.dropLast("(HTTP)".count)).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty, !target.isEmpty else { return nil }

        let statusText = String(line[statusSplit.upperBound...]).trimmingCharacters(in: .whitespaces)
        let state: MCPHealthStatus.State
        if statusText.hasPrefix("✔") {
            state = .connected
        } else if statusText == "! Needs authentication" {
            state = .needsAuth
        } else if statusText.hasPrefix("✗") {
            state = .failed(String(statusText.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else {
            state = .unknown(statusText)  // preserved verbatim, never guessed
        }
        return MCPHealthStatus(name: name, target: target, isHTTP: isHTTP, state: state)
    }
}
