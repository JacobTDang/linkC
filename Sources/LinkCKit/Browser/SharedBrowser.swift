import CryptoKit
import Darwin
import Foundation

/// One session's share of a project's browser: the port of its Chrome and the agent-browser
/// session its MCP server attaches as, pinned to a tab of its own.
public struct SharedBrowserLease: Equatable, Sendable {
    public let port: Int
    public let sessionName: String
    /// The agent's own agent-browser server, which the variables are for.
    public let server: AgentBrowserServer

    public var environment: [String: String] {
        ["AGENT_BROWSER_CDP": String(port), "AGENT_BROWSER_PIN_TAB": "1", "AGENT_BROWSER_SESSION": sessionName]
    }
}

/// Owns one headless Chrome per repository and gives every linkC session its own pinned tab in it.
///
/// A session is counted before anything external runs, and uncounted before its tabs are closed,
/// so a start or an end that lands while another is waiting sees the right number. Every wait —
/// for Chrome's port, for a closed tab, for agent-browser — is an `await`; nothing here blocks the
/// main thread.
@MainActor
public final class SharedBrowser {
    public static let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    /// How long a new Chrome has to publish its DevTools port.
    nonisolated static let portTimeout: TimeInterval = 5
    /// How long after a failed start a project's next session tries again.
    static let retryDelay: TimeInterval = 60
    /// How long a start waits for the project's own Chrome that was told to stop, before killing it.
    nonisolated static let stopTimeout: TimeInterval = 5

    private struct Running: Sendable {
        let id: UUID
        let process: any SharedBrowserProcess
        let port: Int
        /// Every page target seen so far, so a new one can be told from an old one.
        var known: Set<String>
        /// The sessions each tab may belong to; it is closed when the last of them ends. Chrome's
        /// own first tab has none.
        var owners: [String: Set<String>] = [:]

        /// Updates `owners` from one look at the browser. A tab a session is pinned to is that
        /// session's alone. A new tab belongs to the owners of the tab that opened it, and
        /// otherwise to every session attached now, as any of them may have opened it: one
        /// pinned and left between two looks is never seen pinned, and agent-browser's
        /// `Target.createTarget` leaves no opener.
        mutating func track(_ pages: [PageTarget], pins: [String: String], sessions: Set<String>) {
            let open = Set(pages.map(\.id))
            owners = owners.filter { open.contains($0.key) }
            for (session, target) in pins where open.contains(target) { owners[target] = [session] }
            var fresh = pages.filter { !known.contains($0.id) && owners[$0.id] == nil }
            var found = true
            while found {
                found = false
                for page in fresh {
                    guard let opener = page.opener, let by = owners[opener] else { continue }
                    owners[page.id] = by
                    found = true
                }
                fresh.removeAll { owners[$0.id] != nil }
            }
            for page in fresh { owners[page.id] = sessions }
            known = open
        }

        /// Gives up `session`'s claims on the tabs, given the sessions still attached, and returns
        /// the tabs nobody else may own.
        mutating func release(_ session: String, remaining: Set<String>) -> [String] {
            var orphaned: [String] = []
            for (tab, claims) in owners where claims.contains(session) {
                let rest = claims.intersection(remaining)
                if rest.isEmpty {
                    orphaned.append(tab)
                    owners.removeValue(forKey: tab)
                } else {
                    owners[tab] = rest
                }
            }
            return orphaned.sorted()
        }
    }

    private enum Instance {
        case starting(Task<Running?, Never>)
        case running(Running)
    }

    /// A session holding, or waiting for, a share. `project` is nil until its folder is resolved,
    /// `instance` until its Chrome is up.
    private struct Member {
        let sessionName: String
        var project: String?
        var instance: UUID?
        var cli: [String] = []
    }

    private let applicationSupport: URL
    private let agentBrowserHome: URL
    private let chromePath: String
    private let launcher: any SharedBrowserLaunching
    private let devTools: any SharedBrowserDevTools
    private let processes: any SharedBrowserProcessInspecting
    private let runner: any ProcessRunner
    private let executableSearchPath: [String]
    private let discover: @Sendable (AgentKind, String) throws -> AgentBrowserServer?
    private let resolveRepository: @Sendable (String) async throws -> String
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let nonce: () -> String
    private let report: (String) -> Void

    private var instances: [String: Instance] = [:]
    /// Chromes told to stop that had not exited then, per project. One still running holds the
    /// profile's lock, so the project's next start waits for it.
    private var stopping: [String: [UUID: any SharedBrowserProcess]] = [:]
    /// The Chrome each starting project launched, until its start ends: quitting stops it.
    private var launching: [String: any SharedBrowserProcess] = [:]
    private var members: [String: Member] = [:]
    private var repositories: [String: String] = [:]
    private var failedStarts: [String: Date] = [:]
    /// When each project's Chrome was last started again after it died.
    private var restarts: [String: Date] = [:]
    private var reportedKinds: Set<String> = []
    private var cleanups: [UUID: Task<Void, Never>] = [:]
    private var tracking = false

    public init(
        applicationSupport: URL,
        agentBrowserHome: URL,
        chromePath: String = SharedBrowser.chromePath,
        launcher: any SharedBrowserLaunching = LiveSharedBrowserLauncher(),
        devTools: any SharedBrowserDevTools = LiveSharedBrowserDevTools(),
        processes: any SharedBrowserProcessInspecting = LiveSharedBrowserProcesses(),
        runner: any ProcessRunner = LiveProcessRunner(),
        executableSearchPath: [String],
        discover: @escaping @Sendable (AgentKind, String) throws -> AgentBrowserServer?,
        resolveRepository: @escaping @Sendable (String) async throws -> String,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        nonce: @escaping () -> String = { String(UUID().uuidString.prefix(8)).lowercased() },
        report: @escaping (String) -> Void
    ) {
        self.applicationSupport = applicationSupport
        self.agentBrowserHome = agentBrowserHome
        self.chromePath = chromePath
        self.launcher = launcher
        self.devTools = devTools
        self.processes = processes
        self.runner = runner
        self.executableSearchPath = executableSearchPath
        self.discover = discover
        self.resolveRepository = resolveRepository
        self.now = now
        self.sleep = sleep
        self.nonce = nonce
        self.report = report
    }

    // MARK: - Sessions

    /// A share of `cwd`'s repository browser for a session of `agent`, starting that Chrome when
    /// none runs. Nil — and Chrome is never started — when the agent has no agent-browser server,
    /// when its config cannot be read, or when Chrome cannot start; each failure is reported once
    /// per kind. A session released while this waits gets nil.
    public func lease(sessionId: String, agent: AgentKind, cwd: String) async -> SharedBrowserLease? {
        let name = "linkc-\(sessionId)-\(nonce())"
        members[sessionId] = Member(sessionName: name)
        func stillWanted() -> Bool { members[sessionId]?.sessionName == name }

        let discover = self.discover
        let server: AgentBrowserServer?
        do {
            server = try await Task.detached { try discover(agent, cwd) }.value
        } catch {
            members.removeValue(forKey: sessionId)
            reportOnce("config:\(agent.rawValue)", "\(error.localizedDescription). \(agent.displayName) started without the shared browser.")
            return nil
        }
        guard stillWanted() else { return nil }
        guard let server else {
            members.removeValue(forKey: sessionId)
            return nil
        }

        let project = await repository(of: cwd)
        guard stillWanted() else { return nil }
        members[sessionId]?.project = project
        members[sessionId]?.cli = server.cliPrefix

        let running = await instance(for: project)
        guard stillWanted() else {
            stopIfUnused(project)
            return nil
        }
        guard let running else {
            members.removeValue(forKey: sessionId)
            return nil
        }
        members[sessionId]?.instance = running.id
        return SharedBrowserLease(port: running.port, sessionName: name, server: server)
    }

    /// Ends `sessionId`'s share — only the one named `sessionName`, when given, so a late caller
    /// cannot end a newer share of a relaunched session. It is uncounted at once; the last one out
    /// stops Chrome. Its tabs, its agent-browser daemon and the tab agent-browser remembers for it
    /// are cleaned up after.
    public func release(sessionId: String, sessionName: String? = nil) {
        guard let current = members[sessionId], sessionName == nil || current.sessionName == sessionName,
              let member = members.removeValue(forKey: sessionId) else { return }
        guard let project = member.project else { return }
        guard let instanceID = member.instance else {
            stopIfUnused(project)
            return
        }
        var tabs: (port: Int, ids: [String])?
        if case .running(var running)? = instances[project], running.id == instanceID {
            if holders(of: project, instance: instanceID).isEmpty {
                instances.removeValue(forKey: project)
                stop(running, project: project)
            } else {
                let orphaned = running.release(sessionId, remaining: Set(attached(to: instanceID)))
                instances[project] = .running(running)
                tabs = (running.port, orphaned)
            }
        }
        let id = UUID()
        cleanups[id] = Task { [weak self] in
            await self?.cleanUp(member, project: project, instanceID: instanceID, tabs: tabs)
            self?.cleanups.removeValue(forKey: id)
        }
    }

    /// Stops every Chrome and every session's daemon, for quitting: nothing waits, and nothing runs
    /// after linkC quits, so a Chrome still starting is stopped here too, and one that was told to
    /// stop and has not exited is killed.
    public func stopAll() {
        // Forgotten first, so an exit reported at once is not taken for a crash and restarted.
        let all = instances
        instances.removeAll()
        for instance in all.values {
            switch instance {
            case .running(let running): running.process.stop()
            case .starting(let task): task.cancel()
            }
        }
        for process in launching.values { process.stop() }
        launching.removeAll()
        for process in stopping.values.flatMap(\.values) where process.isRunning { process.kill() }
        stopping.removeAll()
        for member in members.values where member.instance != nil {
            if let command = daemonCloseCommand(for: member) {
                do {
                    try launcher.runDetached(executable: command[0], arguments: Array(command.dropFirst()), environment: agentEnvironment)
                } catch {
                    NSLog("[linkC browser] could not stop agent-browser session %@ — %@", member.sessionName, String(describing: error))
                }
            }
            removeTargetFile(of: member)
        }
        members.removeAll()
    }

    /// Notes which sessions each tab may belong to (`Running.track`): the tab agent-browser has a
    /// session pinned to now (`tab_new` moves the pin), a popup by the tab that opened it. Called on
    /// the coordinator's sweep; a call while one runs returns at once.
    public func trackTabs() async {
        guard !tracking else { return }
        tracking = true
        defer { tracking = false }
        for (project, instance) in instances {
            guard case .running(let running) = instance, !attached(to: running.id).isEmpty else { continue }
            let pages: [PageTarget]
            do {
                pages = try await devTools.pageTargets(port: running.port)
            } catch {
                reportOnce("tabs", "linkC could not list the shared browser's tabs for \(project) — \(error.localizedDescription)")
                continue
            }
            guard case .running(var current)? = instances[project], current.id == running.id else { continue }
            let sessions = attached(to: current.id)
            current.track(pages, pins: pins(of: sessions), sessions: Set(sessions))
            instances[project] = .running(current)
        }
    }

    /// The tab agent-browser has each of `sessions` pinned to, where it has one.
    private func pins(of sessions: [String]) -> [String: String] {
        var pins: [String: String] = [:]
        for sessionId in sessions {
            guard let name = members[sessionId]?.sessionName, let target = pinnedTarget(of: name) else { continue }
            pins[sessionId] = target
        }
        return pins
    }

    /// Test seam: waits for every release's cleanup and every start to finish.
    func settle() async {
        while true {
            if let next = cleanups.values.first {
                await next.value
            } else if let start = instances.values.lazy.compactMap({ if case .starting(let task) = $0 { task } else { nil } }).first {
                _ = await start.value
            } else {
                return
            }
        }
    }

    /// Stops `project`'s running Chrome when no session holds or waits for it.
    private func stopIfUnused(_ project: String) {
        guard case .running(let running)? = instances[project], holders(of: project, instance: running.id).isEmpty else { return }
        instances.removeValue(forKey: project)
        stop(running, project: project)
    }

    private func stop(_ running: Running, project: String) {
        stop(running.process, id: running.id, project: project)
    }

    /// Asks a Chrome to quit without waiting; until it exits, the project's next start waits for it.
    private func stop(_ process: any SharedBrowserProcess, id: UUID, project: String) {
        process.stop()
        if process.isRunning { stopping[project, default: [:]][id] = process }
    }

    /// Waits for `project`'s own Chromes that were told to stop and have not exited: a new Chrome on
    /// their profile would abort, and their lock names linkC as the parent, which reads as another
    /// program's. One still running after `stopTimeout` is killed.
    private func awaitStopping(in project: String) async throws {
        func stillRunning() -> [any SharedBrowserProcess] {
            stopping[project] = stopping[project]?.filter { $0.value.isRunning }
            if stopping[project]?.isEmpty == true { stopping.removeValue(forKey: project) }
            return stopping[project].map { Array($0.values) } ?? []
        }
        guard !stillRunning().isEmpty else { return }
        let deadline = now().addingTimeInterval(Self.stopTimeout)
        while !stillRunning().isEmpty, now() < deadline { try await sleep(0.05) }
        let stuck = stillRunning()
        guard !stuck.isEmpty else { return }
        NSLog("[linkC browser] %@: the Chrome linkC stopped had not exited after %.0f s; killing it", project, Self.stopTimeout)
        for process in stuck { process.kill() }
        let killDeadline = now().addingTimeInterval(1)
        while !stillRunning().isEmpty, now() < killDeadline { try await sleep(0.05) }
        guard stillRunning().isEmpty else { throw StartFailure.ownWouldNotStop }
    }

    private func holders(of project: String, instance: UUID) -> [String] {
        members.filter { $0.value.project == project && ($0.value.instance == instance || $0.value.instance == nil) }
            .map(\.key).sorted()
    }

    /// The sessions that have the port of Chrome `instance`.
    private func attached(to instance: UUID) -> [String] {
        members.filter { $0.value.instance == instance }.map(\.key).sorted()
    }

    /// Closes `tabs`, and the tab `member` is pinned to now, but never one another session is pinned
    /// to now; then stops its daemon and forgets its tab.
    private func cleanUp(_ member: Member, project: String, instanceID: UUID, tabs: (port: Int, ids: [String])?) async {
        if let tabs {
            var closing = Set(tabs.ids)
            if let pinned = pinnedTarget(of: member.sessionName) { closing.insert(pinned) }
            closing.subtract(pins(of: attached(to: instanceID)).values)
            for tab in closing.sorted() {
                guard case .running(let running)? = instances[project], running.id == instanceID else { break }
                do {
                    try await devTools.closeTarget(tab, port: tabs.port)
                } catch {
                    reportOnce("tab-close", "linkC could not close a tab of the shared browser for \(project) — \(error.localizedDescription)")
                }
            }
        }
        await stopDaemon(of: member)
        removeTargetFile(of: member)
    }

    // MARK: - agent-browser's own state

    private func targetFile(of name: String) -> URL {
        agentBrowserHome.appendingPathComponent("\(name).target")
    }

    /// The target agent-browser has `name` pinned to, from its `<session>.target`; nil when the
    /// session never used the browser.
    private func pinnedTarget(of name: String) -> String? {
        let file = targetFile(of: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            return object?["targetId"] as? String
        } catch {
            reportOnce("target-file", "linkC could not read agent-browser's \(file.path) — \(error.localizedDescription)")
            return nil
        }
    }

    private func removeTargetFile(of member: Member) {
        let file = targetFile(of: member.sessionName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            reportOnce("target-file", "linkC could not remove agent-browser's \(file.path) — \(error.localizedDescription)")
        }
    }

    /// The PATH linkC's agent terminals get, which the agent's own MCP server was found and runs
    /// on: `npx` and node scripts need node, and a Finder-launched linkC's own PATH has none.
    private var agentEnvironment: [String: String] {
        ["PATH": executableSearchPath.joined(separator: ":")]
    }

    /// `agent-browser --session <name> close --json`, run through the server's own command. Nil when
    /// that command is not found; the reason is reported.
    private func daemonCloseCommand(for member: Member) -> [String]? {
        guard let program = member.cli.first else { return nil }
        let executable: String
        if program.hasPrefix("/") {
            executable = program
        } else if let found = executableSearchPath.lazy.map({ ($0 as NSString).appendingPathComponent(program) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            executable = found
        } else {
            reportOnce("daemon-missing", "linkC could not stop agent-browser's session \(member.sessionName): \(program) was not found on the PATH (\(executableSearchPath.joined(separator: ":")))")
            return nil
        }
        return [executable] + member.cli.dropFirst() + ["--session", member.sessionName, "close", "--json"]
    }

    private func stopDaemon(of member: Member) async {
        guard let command = daemonCloseCommand(for: member) else { return }
        do {
            let result = try await runner.runCapturing(
                command[0], args: Array(command.dropFirst()), cwd: nil, env: agentEnvironment, timeout: 15)
            guard result.status == 0 else {
                // With --json agent-browser writes its error to stdout.
                let said = [result.stdout, result.stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    .joined(separator: " ")
                reportOnce("daemon-close", "agent-browser could not stop session \(member.sessionName) (status \(result.status)): \(said.isEmpty ? "it said nothing" : String(said.prefix(600)))")
                return
            }
        } catch {
            reportOnce("daemon-close", "agent-browser could not stop session \(member.sessionName) — \(error.localizedDescription)")
        }
    }

    // MARK: - Chrome

    /// The running Chrome for `project`: the one up, the one starting, or a new one. Nil within a
    /// minute of a failed start, and when this start fails.
    private func instance(for project: String) async -> Running? {
        if case .running(let running)? = instances[project] {
            if running.process.isRunning { return running }
            chromeExited(project: project, id: running.id, status: nil)
        }
        if case .starting(let task)? = instances[project] { return await task.value }
        if let failedAt = failedStarts[project], now().timeIntervalSince(failedAt) < Self.retryDelay {
            NSLog("[linkC browser] %@: not starting Chrome again yet; the last start failed %.0f s ago",
                  project, now().timeIntervalSince(failedAt))
            return nil
        }
        let task = Task { await self.start(project: project) }
        instances[project] = .starting(task)
        return await task.value
    }

    /// A Chrome that died while sessions used it, started again on the port they have.
    private struct Restart {
        let replacing: UUID
        let port: Int
        /// How it died, for the notice.
        let how: String
    }

    private func start(project: String, restart: Restart? = nil) async -> Running? {
        defer { launching.removeValue(forKey: project) }
        do {
            var running = try await launchChrome(for: project, port: restart?.port ?? 0)
            guard case .starting? = instances[project] else {
                stop(running, project: project)
                return nil
            }
            do {
                running.known = Set(try await devTools.pageTargets(port: running.port).map(\.id))
            } catch {
                reportOnce("tabs", "linkC could not list the shared browser's tabs for \(project) — \(error.localizedDescription)")
            }
            failedStarts.removeValue(forKey: project)
            instances[project] = .running(running)
            if let restart {
                for (sessionId, member) in members where member.instance == restart.replacing {
                    members[sessionId]?.instance = running.id
                }
                reportOnce("chrome-restarted", "The shared browser for \(project) stopped\(restart.how), and linkC started it again on the same port. Sessions there keep the browser; each one's open tab is gone, and agent-browser's next call there says to open a new one.")
                // Every session may have ended while it started.
                stopIfUnused(project)
                guard case .running(let current)? = instances[project], current.id == running.id else { return nil }
            }
            return running
        } catch is CancellationError {
            instances.removeValue(forKey: project)
            return nil
        } catch {
            instances.removeValue(forKey: project)
            let failure = error as? StartFailure ?? .other(error.localizedDescription)
            if let restart {
                // A next session may still start one on a new port, so the project is not held back.
                reportOnce("chrome-restart-failed", "The shared browser for \(project) stopped\(restart.how) and could not start again on its port \(restart.port): \(failure.message(project: project)) Sessions already open there lose the browser; the next session starts a new one.")
            } else {
                failedStarts[project] = now()
                reportOnce("start:\(failure.kind)", "\(failure.message(project: project)) Sessions there start without the shared browser for now.")
            }
            return nil
        }
    }

    private enum StartFailure: Error {
        case chromeMissing(String)
        case inUse(pid: Int32)
        case leftoverWouldNotStop(pid: Int32)
        case ownWouldNotStop
        case portTaken(Int)
        case exited(log: String)
        case noPort
        case other(String)

        var kind: String {
            switch self {
            case .chromeMissing: return "chrome-missing"
            case .inUse: return "in-use"
            case .leftoverWouldNotStop: return "leftover"
            case .ownWouldNotStop: return "own-stuck"
            case .portTaken: return "port-taken"
            case .exited: return "exited"
            case .noPort: return "no-port"
            case .other: return "other"
            }
        }

        func message(project: String) -> String {
            switch self {
            case .chromeMissing(let path):
                return "Google Chrome is not installed at \(path)."
            case .inUse(let pid):
                return "The shared browser profile for \(project) is held by another program's Chrome (pid \(pid))."
            case .leftoverWouldNotStop(let pid):
                return "A Chrome a previous linkC left running for \(project) (pid \(pid)) did not stop."
            case .ownWouldNotStop:
                return "The shared browser linkC stopped for \(project) did not exit, even when killed."
            case .portTaken(let port):
                return "Another program holds port \(port)."
            case .exited(let log):
                return "Google Chrome exited before it published its DevTools port for \(project)\(log.isEmpty ? "." : ": \(log)")"
            case .noPort:
                return "Google Chrome did not publish a DevTools port for \(project) within \(Int(SharedBrowser.portTimeout)) seconds."
            case .other(let reason):
                return "Google Chrome could not start for \(project) — \(reason)."
            }
        }
    }

    /// Starts Chrome for `project` on `port`, or on a port Chrome picks when it is 0.
    private func launchChrome(for project: String, port asked: Int) async throws -> Running {
        guard launcher.isExecutable(chromePath) else { throw StartFailure.chromeMissing(chromePath) }
        let profile = Self.profileDirectory(for: project, in: applicationSupport)
        let portFile = profile.appendingPathComponent("DevToolsActivePort")
        let log = Self.logFile(for: project, in: applicationSupport)
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        } catch {
            throw StartFailure.other("could not create \(profile.path): \(error.localizedDescription)")
        }
        try await awaitStopping(in: project)
        try await stopLeftover(in: profile)
        if FileManager.default.fileExists(atPath: portFile.path) {
            do {
                try FileManager.default.removeItem(at: portFile)
            } catch {
                throw StartFailure.other("could not remove the old \(portFile.path): \(error.localizedDescription)")
            }
        }
        let id = UUID()
        let process: any SharedBrowserProcess
        try Task.checkCancellation()
        do {
            process = try launcher.launch(
                executable: chromePath,
                // A blank first page, not Chrome's new-tab page: with that, the first pinned attach adds
                // one more blank tab. The first attach still opens its own tab, so this page stays open
                // and idle for Chrome's life.
                arguments: ["--headless=new", "--remote-debugging-port=\(asked)", "--user-data-dir=\(profile.path)",
                            "--no-first-run", "--no-default-browser-check", "about:blank"],
                log: log,
                onExit: { [weak self] status in self?.chromeExited(project: project, id: id, status: status) })
        } catch {
            throw StartFailure.other(error.localizedDescription)
        }
        launching[project] = process
        do {
            let port = try await waitForPort(asked, in: portFile, of: process, log: log)
            return Running(id: id, process: process, port: port, known: [])
        } catch {
            stop(process, id: id, project: project)
            throw error
        }
    }

    /// The port Chrome listens on. For a port it picks (`asked` 0) Chrome writes it to
    /// `DevToolsActivePort`. For a port it was given it writes no file, only `DevTools listening on
    /// ws://127.0.0.1:<port>/…` on stderr, the line Puppeteer reads too; when another program holds
    /// that port on 127.0.0.1 it logs the failed bind and listens on ::1 instead.
    private func waitForPort(_ asked: Int, in file: URL, of process: any SharedBrowserProcess, log: URL) async throws -> Int {
        let deadline = now().addingTimeInterval(Self.portTimeout)
        while true {
            if asked == 0 {
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let first = text.split(whereSeparator: \.isNewline).first,
                   let port = Int(first), (1...65_535).contains(port) {
                    return port
                }
            } else if let said = try? String(contentsOf: log, encoding: .utf8) {
                if said.contains("DevTools listening on ws://127.0.0.1:\(asked)/") { return asked }
                if said.contains("Address already in use") { throw StartFailure.portTaken(asked) }
            }
            guard process.isRunning else { throw StartFailure.exited(log: Self.lastLine(of: log)) }
            guard now() < deadline else { throw StartFailure.noPort }
            try await sleep(0.05)
        }
    }

    private static func lastLine(of log: URL) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0.prefix(300)) } ?? ""
    }

    /// A linkC that crashed leaves its Chrome running under launchd, holding the profile's
    /// `SingletonLock`, and a second Chrome on that profile aborts. That leftover — Chrome named in
    /// the lock, on this profile, with launchd as its parent — is stopped. A Chrome on this profile
    /// whose parent is alive belongs to someone else and is left alone.
    private func stopLeftover(in profile: URL) async throws {
        let lock = profile.appendingPathComponent("SingletonLock")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path),
              let pidText = destination.split(separator: "-").last, let pid = Int32(pidText),
              let arguments = processes.arguments(of: pid),
              arguments.contains("--user-data-dir=\(profile.path)") else { return }
        guard processes.parent(of: pid) == 1 else { throw StartFailure.inUse(pid: pid) }
        NSLog("[linkC browser] stopping the Chrome a previous linkC left running on %@ (pid %d)", profile.path, pid)
        for signal in [SIGTERM, SIGKILL] {
            processes.signal(pid, signal)
            for _ in 0..<50 {
                if processes.arguments(of: pid) == nil { return }
                try? await sleep(0.1)
            }
        }
        throw StartFailure.leftoverWouldNotStop(pid: pid)
    }

    private func chromeExited(project: String, id: UUID, status: Int32?) {
        stopping[project]?.removeValue(forKey: id)
        if stopping[project]?.isEmpty == true { stopping.removeValue(forKey: project) }
        guard case .running(let running)? = instances[project], running.id == id else { return }
        instances.removeValue(forKey: project)
        let how = status.map { " (exit status \($0))" } ?? ""
        guard !attached(to: id).isEmpty else {
            reportOnce("chrome-stopped", "The shared browser for \(project) stopped\(how). The next session there starts a new one.")
            return
        }
        // Started again at once on the same port, so the sessions' agent-browser reconnects on its
        // next call; nothing is typed into the agents. Not again within a minute: one that keeps
        // dying is left down.
        if let last = restarts[project], now().timeIntervalSince(last) < Self.retryDelay {
            reportOnce("chrome-stopped-again", "The shared browser for \(project) stopped again\(how) within a minute of linkC starting it again, so it was left down. Sessions already open there lose the browser; the next session starts a new one.")
            return
        }
        restarts[project] = now()
        let restart = Restart(replacing: id, port: running.port, how: how)
        instances[project] = .starting(Task { await self.start(project: project, restart: restart) })
    }

    private func reportOnce(_ kind: String, _ message: String) {
        NSLog("[linkC browser] %@", message)
        if reportedKinds.insert(kind).inserted { report(message) }
    }

    // MARK: - Repositories

    private func repository(of cwd: String) async -> String {
        if let known = repositories[cwd] { return known }
        let root: String
        do {
            root = try await resolveRepository(cwd)
        } catch {
            root = ProjectPath.canonical(cwd)
            reportOnce("repository", "linkC could not find the repository of \(cwd), so its sessions share a browser with that folder only — \(error.localizedDescription)")
        }
        repositories[cwd] = root
        return root
    }

    /// The folder every checkout of `cwd`'s repository shares a browser under: the parent of git's
    /// common folder, so a linked worktree and a subfolder give the main checkout. Outside a
    /// repository, the folder itself. Throws when git cannot answer for a folder inside one.
    public nonisolated static func repositoryRoot(of cwd: String, runner: any ProcessRunner, git: String?) async throws -> String {
        let folder = ProjectPath.canonical(cwd)
        guard GitClient.isRepository(URL(fileURLWithPath: folder)) else { return folder }
        guard let git else { throw LinkCError.process("git was not found in \(GitClient.candidatePaths.joined(separator: ", "))") }
        let result = try await runner.runCapturing(
            git, args: ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: nil, timeout: 10)
        let common = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !common.isEmpty else {
            throw LinkCError.process("git rev-parse --git-common-dir failed in \(folder): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let url = URL(fileURLWithPath: common)
        return ProjectPath.canonical(url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : url.path)
    }

    static func profileDirectory(for project: String, in applicationSupport: URL) -> URL {
        browserFolder(in: applicationSupport).appendingPathComponent(digest(of: project), isDirectory: true)
    }

    static func logFile(for project: String, in applicationSupport: URL) -> URL {
        browserFolder(in: applicationSupport).appendingPathComponent("\(digest(of: project)).log")
    }

    private static func browserFolder(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("browser", isDirectory: true)
    }

    private static func digest(of project: String) -> String {
        SHA256.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
