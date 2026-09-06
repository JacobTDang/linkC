import Foundation
import Darwin

/// Inspects process trees to dynamically detect whether an AI agent CLI is active in a terminal.
public struct ProcessSnooper: Sendable {

    /// Pure matcher: checks if an executable path corresponds to a known AI agent CLI.
    public static func detectAgent(inPath path: String) -> AgentKind? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lastComponent = (trimmed as NSString).lastPathComponent
        switch lastComponent {
        case "claude":
            return .claude
        case "agy":
            return .agy
        case "cursor":
            return .cursor
        case "codex":
            return .codex
        default:
            return nil
        }
    }

    /// Queries the Darwin kernel for child processes of `ppid` and returns the first detected `AgentKind`.
    public static func detectAgent(inProcessTreeOf ppid: pid_t) -> AgentKind? {
        guard ppid > 0 else { return nil }

        var childPids = [pid_t](repeating: 0, count: 64)
        let bytesReturned = proc_listpids(
            UInt32(PROC_PPID_ONLY),
            UInt32(ppid),
            &childPids,
            Int32(MemoryLayout<pid_t>.stride * childPids.count)
        )

        guard bytesReturned > 0 else { return nil }
        let count = Int(bytesReturned) / MemoryLayout<pid_t>.stride

        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for i in 0..<count {
            let childPid = childPids[i]
            guard childPid > 0 else { continue }

            let pathLen = proc_pidpath(childPid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLen > 0 {
                let path = String(cString: pathBuffer)
                if let agent = detectAgent(inPath: path) {
                    return agent
                }
                // Recursively check grandchildren (e.g. wrapper script -> node -> agent)
                if let grandChildAgent = detectAgent(inProcessTreeOf: childPid) {
                    return grandChildAgent
                }
            }
        }

        return nil
    }
}
