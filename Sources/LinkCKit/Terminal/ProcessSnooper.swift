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
        case "cursor", "cursor-agent":
            return .cursor
        case "codex":
            return .codex
        default:
            if trimmed.contains("cursor-agent") {
                return .cursor
            }
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
                let path = pathBuffer.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
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

    /// Checks if `ppid` has any active running child processes (e.g. running a shell command, tool, compiler, or script).
    public static func hasChildProcesses(of ppid: pid_t) -> Bool {
        guard ppid > 0 else { return false }
        var childPids = [pid_t](repeating: 0, count: 16)
        let bytesReturned = proc_listpids(
            UInt32(PROC_PPID_ONLY),
            UInt32(ppid),
            &childPids,
            Int32(MemoryLayout<pid_t>.stride * childPids.count)
        )
        return bytesReturned > 0
    }

    /// Parent pid via `proc_pidinfo(PROC_PIDTBSDINFO)`. Nil for invalid pids or when the kernel refuses.
    public static func parentPid(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Walks *up* from `pid` (exclusive) through at most `maxDepth` parents and returns the first
    /// ancestor whose executable is a known AI CLI, with that ancestor's pid.
    public static func detectAgent(inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> (agent: AgentKind, pid: pid_t)? {
        guard pid > 0, maxDepth > 0 else { return nil }
        var current = pid
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for _ in 0..<maxDepth {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            let len = proc_pidpath(parent, &pathBuffer, UInt32(pathBuffer.count))
            if len > 0 {
                let path = pathBuffer.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
                if let agent = detectAgent(inPath: path) {
                    return (agent, parent)
                }
            }
            current = parent
        }
        return nil
    }
}
