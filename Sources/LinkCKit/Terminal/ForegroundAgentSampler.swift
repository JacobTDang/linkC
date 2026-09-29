import Foundation

/// The system calls behind agent detection, gathered so a test can count them and script their
/// answers. Each one is a kernel round trip per process it looks at.
struct AgentProbe {
    /// The agent running beneath `pid`, found by walking its process tree.
    var inTree: (_ pid: pid_t) -> AgentKind?
    /// The agent `pid` is, or runs beneath it.
    var atOrUnder: (_ pid: pid_t) -> AgentKind?
    /// The foreground process group of the terminal `pid` runs in; nil when the kernel refuses.
    var foregroundGroup: (_ pid: pid_t) -> pid_t?
    var now: () -> Date

    static var live: AgentProbe {
        AgentProbe(
            inTree: { ProcessSnooper.detectAgent(inProcessTreeOf: $0) },
            atOrUnder: { ProcessSnooper.detectAgent(atOrUnder: $0) },
            foregroundGroup: { ProcessSnooper.terminalForegroundGroup(of: $0) },
            now: Date.init
        )
    }
}

/// Decides when a terminal's process tree has to be walked again to see which agent is running in
/// it. The walk is a `proc_listpids` and a `proc_pidpath` per process, and a busy shell makes it
/// wider, so the answer is kept until something suggests it changed: the terminal's foreground
/// process group moved (a new command, or the agent starting or exiting), or a while has passed
/// (a wrapper that execs another agent keeps its pid, and so its process group).
struct ForegroundAgentSampler {
    /// The longest an answer is kept when the foreground process group does not move.
    static let reprobeInterval: TimeInterval = 10

    private var last: (foreground: pid_t?, at: Date, agent: AgentKind?)?

    /// The agent running in the terminal: the kept answer while it still holds, else `probe`'s.
    /// `foreground` is nil when the terminal's foreground group could not be read, which leaves
    /// only the timer to say the answer is stale.
    mutating func sample(foreground: pid_t?, now: Date, probe: () -> AgentKind?) -> AgentKind? {
        if let last, last.foreground == foreground {
            let age = now.timeIntervalSince(last.at)
            // A clock that went backwards proves nothing about how old the answer is.
            if age >= 0, age < Self.reprobeInterval { return last.agent }
        }
        let agent = probe()
        last = (foreground, now, agent)
        return agent
    }

    /// Drops the kept answer, so the next `sample` probes.
    mutating func forget() {
        last = nil
    }
}
