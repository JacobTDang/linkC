import Foundation

/// The `linkc` command: `linkc <agent> [--tier T] [--task] [prompt ...]` asks linkC to open the agent in a
/// new window, in the current folder, with the prompt typed in. Parsing and running are here, with the
/// outside world injected; the executable only wires the real one in.
public enum LinkCCommand {
    public static let usage = """
        Usage: linkc <agent> [--tier light|standard|deep] [--task] [prompt ...]

        Opens <agent> in a new linkC window, in the current folder, with the prompt typed in.
          <agent>   claude, codex, agy, cursor or grok
          --tier    the model tier (default: the agent's default in linkC's Settings > Models)
          --task    for an agent handing off work: the new session carries the prompt as a task
                    the calling agent can follow (linkc_get_task) and close (linkc_close_worker)
        """

    /// The agents the command opens: every kind but the shell.
    static let agents: [AgentKind] = AgentKind.allCases.filter { $0 != .shell }

    public struct Invocation: Equatable, Sendable {
        public let agent: AgentKind
        public let tier: ModelTier?
        public let task: Bool
        public let prompt: String?
    }

    public enum Parsed: Equatable, Sendable {
        case help
        case open(Invocation)
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public struct LaunchError: Error, CustomStringConvertible {
        public let status: Int32
        public var description: String { "`open` exited with status \(status)" }
    }

    public static func parse(_ arguments: [String]) throws -> Parsed {
        if arguments.contains("--help") || arguments.contains("-h") { return .help }
        let names = agents.map(\.rawValue).joined(separator: ", ")
        var agent: AgentKind?
        var tier: ModelTier?
        var task = false
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                words.append(contentsOf: arguments[index...])
                break
            }
            if argument == "--task" {
                task = true
            } else if argument == "--tier" {
                guard index < arguments.count else { throw UsageError(description: "--tier needs a value: light, standard or deep") }
                guard let value = ModelTier(rawValue: arguments[index]) else {
                    throw UsageError(description: "unknown tier \"\(arguments[index])\": use light, standard or deep")
                }
                tier = value
                index += 1
            } else if (argument.hasPrefix("-") && agent == nil) || argument.hasPrefix("--") {
                throw UsageError(description: "unknown option \(argument)")
            } else if agent == nil {
                guard let kind = AgentKind(rawValue: argument), agents.contains(kind) else {
                    throw UsageError(description: "unknown agent \"\(argument)\": use \(names)")
                }
                agent = kind
            } else {
                words.append(argument)
            }
        }
        guard let agent else { throw UsageError(description: "name an agent: \(names)") }
        let prompt = words.isEmpty ? nil : words.joined(separator: " ")
        if task && prompt == nil { throw UsageError(description: "--task needs a prompt: the work to hand off") }
        return .open(Invocation(agent: agent, tier: tier, task: task, prompt: prompt))
    }

    /// What running the command needs from the outside world.
    public struct Environment {
        public var store: OpenRequestStore
        /// The folder the command runs in.
        public var folder: String
        /// The agent this command runs under, and its linkC session when it has one.
        public var caller: () -> (agent: AgentKind, sessionId: String?)?
        public var isLinkCRunning: () -> Bool
        public var launchLinkC: () throws -> Void
        public var now: () -> Date
        public var sleep: (TimeInterval) -> Void
        public var timeout: TimeInterval = 20
        public var pollInterval: TimeInterval = 0.1

        public init(store: OpenRequestStore, folder: String, caller: @escaping () -> (agent: AgentKind, sessionId: String?)?,
                    isLinkCRunning: @escaping () -> Bool, launchLinkC: @escaping () throws -> Void,
                    now: @escaping () -> Date, sleep: @escaping (TimeInterval) -> Void) {
            self.store = store
            self.folder = folder
            self.caller = caller
            self.isLinkCRunning = isLinkCRunning
            self.launchLinkC = launchLinkC
            self.now = now
            self.sleep = sleep
        }
    }

    /// Asks linkC to open `invocation` and waits for its answer. Returns the exit status and the line to
    /// print: on standard output for 0, on standard error otherwise.
    public static func run(_ invocation: Invocation, in env: Environment) -> (status: Int32, output: String) {
        var origin: OpenRequest.TaskOrigin?
        if invocation.task {
            guard let caller = env.caller() else {
                return (1, "linkc: --task is for an agent handing off work; run without --task to open your own session.")
            }
            origin = OpenRequest.TaskOrigin(fromAgent: caller.agent, fromSessionId: caller.sessionId)
        }
        let request = OpenRequest(agent: invocation.agent, folder: ProjectPath.canonical(env.folder),
                                  prompt: invocation.prompt, tier: invocation.tier, task: origin, createdAt: env.now())
        do {
            try env.store.submit(request)
        } catch {
            return (1, "linkc: the request for linkC could not be written — \(error)")
        }
        if !env.isLinkCRunning() {
            do {
                try env.launchLinkC()
            } catch {
                return (1, "linkc: linkC is not running and could not be started — \(error)")
            }
        }
        let deadline = env.now().addingTimeInterval(env.timeout)
        while true {
            let answer: OpenResult?
            do {
                answer = try env.store.result(for: request.id)
            } catch {
                return (1, "linkc: linkC's answer could not be read — \(error)")
            }
            if let answer {
                do {
                    try env.store.removeResult(for: request.id)
                } catch {
                    return (1, "linkc: \(answer.message) (its answer file could not be removed — \(error))")
                }
                return answer.ok ? (0, answer.message) : (1, "linkc: \(answer.message)")
            }
            if env.now() >= deadline {
                do {
                    try env.store.withdraw(request.id)
                } catch {
                    return (1, "linkc: linkC did not answer within \(Int(env.timeout)) seconds, and the request could not be withdrawn — \(error)")
                }
                return (1, "linkc: linkC did not answer within \(Int(env.timeout)) seconds. Is it running?")
            }
            env.sleep(env.pollInterval)
        }
    }
}
