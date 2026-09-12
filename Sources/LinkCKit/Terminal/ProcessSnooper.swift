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

    /// Raw `KERN_PROCARGS2` bytes for `pid`: argc, the exec path, argv, then the process's
    /// environment — the only way to read another same-user process's environment on macOS.
    /// Nil when the kernel refuses (a different user's process, or one that has already exited).
    static func procArgs2Buffer(for pid: pid_t) -> [UInt8]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { ptr in
            sysctl(&mib, 3, ptr.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Reads a single NUL-terminated C string starting at `offset`, returning it and the offset
    /// just past its terminator (or the buffer's end, if the string runs off the end unterminated).
    static func cString(in buffer: [UInt8], startingAt offset: Int) -> (value: String, next: Int) {
        guard offset < buffer.count else { return ("", offset) }
        var end = offset
        while end < buffer.count, buffer[end] != 0 { end += 1 }
        let value = String(decoding: buffer[offset..<end], as: UTF8.self)
        return (value, end < buffer.count ? end + 1 : end)
    }

    /// Parses a raw `KERN_PROCARGS2` buffer into an environment dictionary. Layout: a native-endian
    /// `Int32` argc, then the saved exec path (NUL-terminated), then padding NUL bytes up to the
    /// start of argv[0], then `argc` NUL-terminated argv strings back to back, then the process's
    /// `NAME=VALUE` environment strings, each NUL-terminated, ending at the buffer's end or at the
    /// first empty string.
    static func parseProcArgs2(_ buffer: [UInt8]) -> [String: String] {
        guard buffer.count >= 4 else { return [:] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var offset = 4
        (_, offset) = cString(in: buffer, startingAt: offset) // exec path
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 } // padding before argv[0]
        var remainingArgs = Int(argc)
        while remainingArgs > 0, offset < buffer.count {
            (_, offset) = cString(in: buffer, startingAt: offset)
            remainingArgs -= 1
        }
        var env: [String: String] = [:]
        while offset < buffer.count {
            let (entry, next) = cString(in: buffer, startingAt: offset)
            guard !entry.isEmpty else { break }
            offset = next
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    /// The value of `name` in `pid`'s environment, read directly from the kernel — for a process
    /// that never inherited it from us. Nil if the kernel refuses or the variable is not set.
    public static func environmentVariable(_ name: String, ofProcess pid: pid_t) -> String? {
        guard let buffer = procArgs2Buffer(for: pid) else { return nil }
        return parseProcArgs2(buffer)[name]
    }

    /// Walks *up* from `pid` (exclusive) through at most `maxDepth` parents and returns the first
    /// `LINKC_SESSION` found in an ancestor's real environment (via `KERN_PROCARGS2`), not ours —
    /// an MCP server spawned without the variable in its own `environment` can still recover it
    /// from a session-bearing ancestor (e.g. Codex's CLI process) that did not pass it down.
    public static func sessionId(inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> String? {
        guard pid > 0, maxDepth > 0 else { return nil }
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if let session = environmentVariable("LINKC_SESSION", ofProcess: parent), !session.isEmpty {
                return session
            }
            current = parent
        }
        return nil
    }
}
