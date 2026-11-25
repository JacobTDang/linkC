import Foundation
@testable import LinkCKit

/// Stand-ins for what `SharedBrowser` drives: Chrome, its DevTools endpoints, other processes, and
/// agent-browser's CLI. Each records what it was asked to do.

@MainActor
final class FakeBrowserProcess: SharedBrowserProcess {
    let pid: Int32
    var isRunning = true
    var stopCount = 0
    var onExit: (@MainActor (Int32) -> Void)?

    init(pid: Int32) { self.pid = pid }

    /// Like Chrome under `terminate()`: it stops, and its exit is reported.
    func stop() {
        stopCount += 1
        guard isRunning else { return }
        exit(status: 15)
    }

    /// Chrome exiting by itself.
    func exit(status: Int32 = 1) {
        isRunning = false
        onExit?(status)
    }
}

@MainActor
final class FakeBrowserLauncher: SharedBrowserLaunching {
    var available = true
    var executableChecks = 0
    var launches: [[String]] = []
    var processes: [FakeBrowserProcess] = []
    /// The port each launch writes to `DevToolsActivePort` at once; nil writes none.
    var publishesPort: Int? = 43117
    var detached: [[String]] = []
    var events: (String) -> Void = { _ in }

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
        processes.append(process)
        if let publishesPort { publish(port: publishesPort) }
        return process
    }

    func runDetached(executable: String, arguments: [String]) throws {
        detached.append([executable] + arguments)
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
    private var _closed: [String] = []
    private var _lists = 0
    var closeError: Error?

    var pages: [String] {
        get { lock.withLock { _pages } }
        set { lock.withLock { _pages = newValue } }
    }
    var closed: [String] { lock.withLock { _closed } }
    var lists: Int { lock.withLock { _lists } }

    func pageTargets(port: Int) async throws -> [String] {
        lock.withLock { _lists += 1; return _pages }
    }

    func closeTarget(_ id: String, port: Int) async throws {
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
    var result = ProcessResult(status: 0, stdout: #"{"success":true}"#, stderr: "")

    var calls: [[String]] { lock.withLock { _calls } }

    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { _calls.append([executable] + args) }
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
