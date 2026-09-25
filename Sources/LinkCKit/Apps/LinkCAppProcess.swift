import Foundation
import Observation

/// Runs one linkC app for one tab.
/// - It picks a free port and starts the app's command in its own process group, through the
///   login shell (`exec "$@"` keeps the pid, so the group is the app's).
/// - It waits for the health URL.
/// - It stops the whole group when the tab closes.
/// It never starts by itself.
@MainActor
@Observable
public final class LinkCAppProcess {
    public enum State: Equatable, Sendable {
        case asleep
        case starting
        case running(URL)
        case failed(reason: String)
        case exited(status: Int32)
    }

    public struct Timing: Sendable {
        public var healthTimeout: TimeInterval
        public var pollInterval: TimeInterval
        public var stopGrace: TimeInterval

        public init(healthTimeout: TimeInterval = 60, pollInterval: TimeInterval = 0.25, stopGrace: TimeInterval = 5) {
            self.healthTimeout = healthTimeout
            self.pollInterval = pollInterval
            self.stopGrace = stopGrace
        }
    }

    /// How the command runs. The login shell with `-l` gives the command the PATH a terminal has
    /// (Homebrew, `~/.local/bin`, version managers), which a Finder-launched app lacks.
    public struct Launcher: Sendable {
        public let shell: String
        public let login: Bool

        public init(shell: String, login: Bool) {
            self.shell = shell
            self.login = login
        }

        public static func loginShell() -> Launcher {
            Launcher(shell: posixShell(for: ShellResolver.loginShell()), login: true)
        }

        /// `exec "$@"` needs a POSIX shell — a fish login shell (its syntax isn't POSIX) would
        /// fail every start. Returns `shell` itself when it already is one, `/bin/zsh` otherwise.
        static func posixShell(for shell: String) -> String {
            let posixShells: Set<String> = ["sh", "bash", "zsh", "ksh", "dash"]
            return posixShells.contains((shell as NSString).lastPathComponent) ? shell : "/bin/zsh"
        }

        func arguments(for argv: [String]) -> [String] {
            (login ? ["-l"] : []) + ["-c", "exec \"$@\"", "linkc-app"] + argv
        }
    }

    public static let logLimit = 200

    public let folder: String
    public var manifest: LinkCAppManifest
    public private(set) var state: State = .asleep
    public private(set) var log: [String] = []

    @ObservationIgnored private let launcher: Launcher
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var group: pid_t?
    /// Bumped by every start and stop. Late callbacks from an older run compare against it and
    /// drop out.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var partialLine = ""
    /// `readabilityHandler`'s dispatch source does not keep this alive on its own — an
    /// unretained `FileHandle` gets deallocated as soon as `start()` returns, closing the read
    /// end early and handing the child SIGPIPE on its next write. Held here for the run's
    /// lifetime; the next `start()` (or dealloc) replaces or drops it.
    @ObservationIgnored private var logHandle: FileHandle?
    /// Where a spawned group is recorded so a crash or force quit of linkC itself doesn't leave
    /// it running forever — nil in most tests, the shared production ledger in the app.
    @ObservationIgnored private let ledger: LinkCAppGroupLedger?

    var processGroup: pid_t? { group }

    /// Groups sent SIGTERM whose SIGKILL escalation is still pending (the `Task` scheduled by
    /// `terminate` hasn't run yet). `stopAll` folds these in too, so a group that outlives the
    /// `LinkCAppProcess` that started it (its tab already closed) still gets caught at quit.
    @MainActor private static var stoppingGroups: Set<pid_t> = []

    public init(
        folder: String, manifest: LinkCAppManifest, launcher: Launcher = .loginShell(), timing: Timing = Timing(),
        ledger: LinkCAppGroupLedger? = nil
    ) {
        self.folder = folder
        self.manifest = manifest
        self.launcher = launcher
        self.timing = timing
        self.ledger = ledger
    }

    /// Starts the app when it isn't already starting or running. Every failure lands in `.failed`
    /// with its reason.
    public func start() {
        switch state {
        case .starting, .running: return
        case .asleep, .failed, .exited: break
        }
        generation += 1
        let run = generation
        log = []
        partialLine = ""
        let launch: LinkCAppManifest.Launch
        do {
            launch = try manifest.launch(port: try Self.choosePort(preferred: manifest.port))
        } catch {
            state = .failed(reason: error.localizedDescription)
            return
        }
        let pipe = Pipe()
        let pid: pid_t
        do {
            pid = try LiveProcessRunner.spawnGroupLeader(
                executable: launcher.shell, args: launcher.arguments(for: launch.argv),
                cwd: URL(fileURLWithPath: folder), environment: launch.environment,
                stdout: pipe.fileHandleForWriting.fileDescriptor, stderr: pipe.fileHandleForWriting.fileDescriptor)
        } catch {
            state = .failed(reason: error.localizedDescription)
            return
        }
        do {
            try pipe.fileHandleForWriting.close()
        } catch {
            NSLog("[linkC app] %@: closing linkC's end of the log pipe failed — %@", manifest.name, String(describing: error))
        }
        group = pid
        state = .starting
        ledger?.record(pid)
        logHandle = pipe.fileHandleForReading
        readLog(pipe.fileHandleForReading, run: run)
        reap(pid, run: run)
        pollHealth(launch.healthURL, page: launch.pageURL, run: run)
    }

    /// Stops the app: SIGTERM to its process group now, SIGKILL after the grace period. Returns at
    /// once, and the state is `.asleep` straight away.
    public func stop() {
        generation += 1
        if let group {
            Self.terminate(group: group, name: manifest.name, folder: folder, grace: timing.stopGrace, ledger: ledger)
        }
        group = nil
        state = .asleep
    }

    /// Stops every process's group, plus any group still escalating from an earlier `stop()`,
    /// and blocks until all of them are gone (one shared grace period, then SIGKILL to whatever
    /// remains). For quitting linkC, when nothing can wait on a timer.
    public static func stopAll(_ processes: [LinkCAppProcess], grace: TimeInterval = 5) {
        var groups: [pid_t: (name: String, folder: String, ledger: LinkCAppGroupLedger?)] = [:]
        for process in processes {
            if let group = process.group {
                groups[group] = (process.manifest.name, process.folder, process.ledger)
                process.generation += 1
                process.group = nil
                process.state = .asleep
            }
        }
        for group in stoppingGroups where groups[group] == nil {
            groups[group] = ("app", "", nil)
        }
        guard !groups.isEmpty else {
            stoppingGroups.removeAll()
            return
        }
        func groupIsGone(_ group: pid_t) -> Bool { kill(-group, 0) == -1 && errno == ESRCH }
        for (group, info) in groups {
            LiveProcessRunner.signalGroup(group, SIGTERM, running: info.name, in: URL(fileURLWithPath: info.folder))
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !groups.keys.allSatisfy(groupIsGone) { usleep(50_000) }
        for (group, info) in groups where !groupIsGone(group) {
            LiveProcessRunner.signalGroup(group, SIGKILL, running: info.name, in: URL(fileURLWithPath: info.folder))
        }
        // SIGKILL cannot be blocked, but a killed process is briefly a zombie until reaped (our
        // own reaper thread for the leader, launchd for an orphaned child) — give that a moment
        // so "gone" really means gone by the time this call returns, not a race with the reaper.
        let reapDeadline = Date().addingTimeInterval(2)
        while Date() < reapDeadline, !groups.keys.allSatisfy(groupIsGone) { usleep(10_000) }
        for (group, info) in groups {
            info.ledger?.forget(group)
        }
        stoppingGroups.removeAll()
    }

    /// SIGTERM now, SIGKILL after `grace` if the group is still alive — scheduled on a `Task` so
    /// it survives only as long as linkC itself does. `stopAll` is what catches a group whose
    /// escalation was still pending when linkC quit.
    private static func terminate(group: pid_t, name: String, folder: String, grace: TimeInterval, ledger: LinkCAppGroupLedger?) {
        let folderURL = URL(fileURLWithPath: folder)
        LiveProcessRunner.signalGroup(group, SIGTERM, running: name, in: folderURL)
        stoppingGroups.insert(group)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(grace))
            if kill(-group, 0) == 0 { // the group is still alive
                LiveProcessRunner.signalGroup(group, SIGKILL, running: name, in: folderURL)
            }
            stoppingGroups.remove(group)
            ledger?.forget(group)
        }
    }

    private func readLog(_ handle: FileHandle, run: Int) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.append(text, run: run) }
        }
    }

    private func append(_ text: String, run: Int) {
        guard run == generation else { return }
        var pieces = (partialLine + text).components(separatedBy: "\n")
        partialLine = pieces.removeLast()
        log.append(contentsOf: pieces)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// Waits for the group leader on a background thread, so it never lingers as a zombie.
    private func reap(_ pid: pid_t, run: Int) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let code = Self.exitCode(status)
            Task { @MainActor [weak self] in self?.leaderExited(pid, code: code, run: run) }
        }
    }

    private func leaderExited(_ pid: pid_t, code: Int32, run: Int) {
        guard run == generation else { return }
        // The leader itself is confirmed gone (we're past its waitpid) — forget it now, rather
        // than waiting on the cleanup below, which only chases down any stray children.
        ledger?.forget(pid)
        // The leader is gone. Anything it started must not live on and draw power.
        Self.terminate(group: pid, name: manifest.name, folder: folder, grace: timing.stopGrace, ledger: ledger)
        group = nil
        if !partialLine.isEmpty {
            log.append(partialLine)
            partialLine = ""
        }
        switch state {
        case .starting:
            if code == 127 {
                state = .failed(reason: "The start command was not found: \(manifest.start.first ?? "")")
            } else {
                state = .failed(reason: "The app exited with status \(code) before it was ready.")
            }
        case .running:
            state = .exited(status: code)
        case .asleep, .failed, .exited:
            break
        }
    }

    private func pollHealth(_ health: URL, page: URL, run: Int) {
        let deadline = Date().addingTimeInterval(timing.healthTimeout)
        let interval = timing.pollInterval
        let seconds = Int(timing.healthTimeout.rounded(.up))
        Task { @MainActor [weak self] in
            while true {
                guard let self, self.generation == run, self.state == .starting else { return }
                if await Self.answers(health) {
                    guard self.generation == run, self.state == .starting else { return }
                    self.state = .running(page)
                    return
                }
                if Date() >= deadline {
                    guard self.generation == run, self.state == .starting else { return }
                    if let group = self.group {
                        Self.terminate(
                            group: group, name: self.manifest.name, folder: self.folder, grace: self.timing.stopGrace,
                            ledger: self.ledger)
                    }
                    self.generation += 1
                    self.group = nil
                    if !self.partialLine.isEmpty {
                        self.log.append(self.partialLine)
                        self.partialLine = ""
                    }
                    self.state = .failed(reason: "The app did not answer \(health.path) within \(seconds) s.")
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private static let healthSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// A 2xx from the health URL. A refused or timed-out request is the normal "not ready yet"
    /// answer while the app starts, not an error to report.
    private static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await healthSession.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The exit code of a raw wait status: the code for a normal exit, 128 + the signal for a kill.
    /// `nonisolated` — computed on the background reaper thread before hopping back to the
    /// main actor, so it must not require actor isolation.
    nonisolated static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// The port for one start: `preferred` when it is free, otherwise a free port.
    static func choosePort(preferred: Int?) throws -> Int {
        // A preferred port that is busy is the normal case for a fallback, not an error to report.
        if let preferred, let port = UInt16(exactly: preferred), (try? bindPort(port)) != nil { return preferred }
        return try freePort()
    }

    /// A free local port, from binding port 0 on 127.0.0.1.
    static func freePort() throws -> Int {
        try bindPort(0)
    }

    /// Binds `port` on 127.0.0.1 (0 for any free port), then releases it, and returns the port
    /// that was bound.
    private static func bindPort(_ port: UInt16) throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw LinkCError.process("could not open a socket to find a free port: \(String(cString: strerror(errno)))")
        }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard bound == 0 else {
            throw LinkCError.process("could not bind a socket to find a free port: \(String(cString: strerror(errno)))")
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else {
            throw LinkCError.process("could not read the free port: \(String(cString: strerror(errno)))")
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
