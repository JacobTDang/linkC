import Foundation
@testable import LinkCKit

/// Stand-ins for what `SharedBrowser` drives: Chrome, its DevTools endpoints, other processes, and
/// agent-browser's CLI. Each records what it was asked to do.

@MainActor
final class FakeBrowserProcess: SharedBrowserProcess {
    let pid: Int32
    var isRunning = true
    var stopCount = 0
    var killCount = 0
    /// A Chrome that takes its time over SIGTERM: `stop()` leaves it running.
    var ignoresStop = false
    var onExit: (@MainActor (Int32) -> Void)?
    var events: (String) -> Void = { _ in }
    /// Runs when it exits, after `onExit`.
    var onExited: () -> Void = {}

    init(pid: Int32) { self.pid = pid }

    /// Like Chrome under `terminate()`: it stops, and its exit is reported.
    func stop() {
        stopCount += 1
        events("stop \(pid)")
        guard isRunning, !ignoresStop else { return }
        exit(status: 15)
    }

    func kill() {
        killCount += 1
        events("kill \(pid)")
        guard isRunning else { return }
        exit(status: 9)
    }

    /// Chrome exiting by itself.
    func exit(status: Int32 = 1) {
        isRunning = false
        onExit?(status)
        onExited()
    }
}

@MainActor
final class FakeBrowserLauncher: SharedBrowserLaunching {
    var available = true
    var executableChecks = 0
    var launches: [[String]] = []
    var processes: [FakeBrowserProcess] = []
    /// The port each launch on port 0 writes to `DevToolsActivePort` at once; nil writes none.
    var publishesPort: Int? = 43117
    var detached: [[String]] = []
    var detachedEnvironments: [[String: String]] = []
    var events: (String) -> Void = { _ in }
    /// Each new Chrome takes its time over SIGTERM.
    var ignoresStop = false
    /// Ports another program holds on 127.0.0.1.
    var takenPorts: Set<Int> = []
    /// When set, each Chrome holds its profile's `SingletonLock` as Chrome does, with linkC as its
    /// parent, and is listed here until it exits.
    var holdsLock: FakeProcesses?

    func isExecutable(_ path: String) -> Bool {
        executableChecks += 1
        return available
    }

    func launch(
        executable: String, arguments: [String], log: URL, onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any SharedBrowserProcess {
        launches.append(arguments)
        events("launch")
        let process = FakeBrowserProcess(pid: Int32(1000 + launches.count))
        process.onExit = onExit
        process.events = { [weak self] in self?.events($0) }
        process.ignoresStop = ignoresStop
        processes.append(process)
        if let holdsLock, let profile {
            let lock = profile.appendingPathComponent("SingletonLock")
            try? FileManager.default.removeItem(at: lock)
            try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: "MyMac-\(process.pid)")
            holdsLock.add(pid: process.pid, arguments: [executable] + arguments, parent: getpid())
            process.onExited = { [pid = process.pid] in holdsLock.remove(pid: pid) }
        }
        let asked = arguments.first { $0.hasPrefix("--remote-debugging-port=") }
            .flatMap { Int($0.dropFirst("--remote-debugging-port=".count)) }
        if let asked, asked != 0 {
            // As Chrome 158 does: a port it was given gets no DevToolsActivePort, only a line on
            // stderr; one held on 127.0.0.1 fails to bind there, and Chrome listens on ::1 instead.
            let said = takenPorts.contains(asked)
                ? "bind() failed: Address already in use (48)\n\nDevTools listening on ws://[::1]:\(asked)/devtools/browser/x\n"
                : "\nDevTools listening on ws://127.0.0.1:\(asked)/devtools/browser/x\n"
            try Data(said.utf8).write(to: log)
        } else if let publishesPort {
            publish(port: publishesPort)
        }
        return process
    }

    func runDetached(executable: String, arguments: [String], environment: [String: String]) throws {
        detached.append([executable] + arguments)
        detachedEnvironments.append(environment)
    }

    /// The profile folder of the last launch.
    var profile: URL? {
        launches.last?.first { $0.hasPrefix("--user-data-dir=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--user-data-dir=".count))) }
    }

    func publish(port: Int) {
        guard let profile else { return }
        try? Data("\(port)\n/devtools/browser/x\n".utf8).write(to: profile.appendingPathComponent("DevToolsActivePort"))
    }
}

final class FakeDevTools: SharedBrowserDevTools, @unchecked Sendable {
    private let lock = NSLock()
    private var _pages: [String] = []
    private var _openers: [String: String] = [:]
    private var _closed: [String] = []
    private var _closeAttempts: [String] = []
    private var _lists = 0
    var closeError: Error?
    var onClose: (@Sendable () async -> Void)?

    var pages: [String] {
        get { lock.withLock { _pages } }
        set { lock.withLock { _pages = newValue } }
    }
    /// The tab that opened each popup.
    var openers: [String: String] {
        get { lock.withLock { _openers } }
        set { lock.withLock { _openers = newValue } }
    }
    var closed: [String] { lock.withLock { _closed } }
    var closeAttempts: [String] { lock.withLock { _closeAttempts } }
    var lists: Int { lock.withLock { _lists } }

    func pageTargets(port: Int) async throws -> [PageTarget] {
        lock.withLock {
            _lists += 1
            return _pages.map { PageTarget(id: $0, opener: _openers[$0]) }
        }
    }

    func closeTarget(_ id: String, port: Int) async throws {
        lock.withLock { _closeAttempts.append(id) }
        if let onClose { await onClose() }
        if let closeError { throw closeError }
        lock.withLock {
            _closed.append(id)
            _pages.removeAll { $0 == id }
        }
    }
}

final class FakeProcesses: SharedBrowserProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [Int32: [String]] = [:]
    private var _parents: [Int32: Int32] = [:]
    private var _signals: [(pid: Int32, signal: Int32)] = []
    var events: @Sendable (String) -> Void = { _ in }

    func add(pid: Int32, arguments: [String], parent: Int32) {
        lock.withLock {
            _arguments[pid] = arguments
            _parents[pid] = parent
        }
    }

    func remove(pid: Int32) {
        lock.withLock {
            _arguments[pid] = nil
            _parents[pid] = nil
        }
    }

    var signals: [(pid: Int32, signal: Int32)] { lock.withLock { _signals } }

    func arguments(of pid: Int32) -> [String]? { lock.withLock { _arguments[pid] } }
    func parent(of pid: Int32) -> Int32? { lock.withLock { _parents[pid] } }

    /// A signal ends the process.
    func signal(_ pid: Int32, _ signal: Int32) {
        lock.withLock {
            _signals.append((pid, signal))
            _arguments[pid] = nil
        }
        events("signal \(signal)")
    }
}

final class RecordingRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _environments: [[String: String]] = []
    var result = ProcessResult(status: 0, stdout: #"{"success":true}"#, stderr: "")

    var calls: [[String]] { lock.withLock { _calls } }
    /// The environment each call was given to merge.
    var environments: [[String: String]] { lock.withLock { _environments } }

    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        try await runCapturing(executable, args: args, cwd: cwd, env: [:], timeout: timeout)
    }

    func runCapturing(_ executable: String, args: [String], cwd: URL?, env: [String: String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock {
            _calls.append([executable] + args)
            _environments.append(env)
        }
        return result
    }
}

/// A clock that moves only when the code under test sleeps.
@MainActor
final class SteppingClock {
    var time = Date(timeIntervalSince1970: 1_000_000)
    var onSleep: () -> Void = {}

    func now() -> Date { time }

    func sleep(_ seconds: TimeInterval) async throws {
        time = time.addingTimeInterval(seconds)
        onSleep()
        await Task.yield()
    }
}

/// A value closures that must be `@Sendable` can read and change.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
