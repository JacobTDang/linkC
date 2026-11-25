import Darwin
import Foundation

/// A Chrome `SharedBrowser` started.
@MainActor
public protocol SharedBrowserProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// Asks it to quit (SIGTERM).
    func stop()
    /// Ends it at once (SIGKILL), for one that did not quit when asked.
    func kill()
}

/// Starts Chrome, and agent-browser where nothing may wait for it.
@MainActor
public protocol SharedBrowserLaunching: AnyObject {
    func isExecutable(_ path: String) -> Bool
    /// Starts `executable` with its output in `log`. `onExit` runs on the main actor when it exits.
    func launch(
        executable: String, arguments: [String], log: URL, onExit: @escaping @MainActor @Sendable (Int32) -> Void
    ) throws -> any SharedBrowserProcess
    /// Starts `executable` with `environment` merged into linkC's own and leaves it running
    /// unwatched, for work at quit.
    func runDetached(executable: String, arguments: [String], environment: [String: String]) throws
}

/// A tab of Chrome's.
public struct PageTarget: Equatable, Sendable {
    public let id: String
    /// The tab that opened it, for a popup.
    public let opener: String?

    public init(id: String, opener: String? = nil) {
        self.id = id
        self.opener = opener
    }
}

/// Chrome's DevTools endpoints.
public protocol SharedBrowserDevTools: Sendable {
    /// Every page target.
    func pageTargets(port: Int) async throws -> [PageTarget]
    /// Closes a target; one that is already gone is not an error.
    func closeTarget(_ id: String, port: Int) async throws
}

/// Other processes, for the Chrome a crashed linkC left behind.
public protocol SharedBrowserProcessInspecting: Sendable {
    /// `pid`'s argv; nil when there is no such process.
    func arguments(of pid: Int32) -> [String]?
    func parent(of pid: Int32) -> Int32?
    func signal(_ pid: Int32, _ signal: Int32)
}

@MainActor
public final class LiveSharedBrowserProcess: SharedBrowserProcess {
    private let process: Process

    init(_ process: Process) { self.process = process }

    public var isRunning: Bool { process.isRunning }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    public func kill() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH else { return }
        NSLog("[linkC browser] SIGKILL to Chrome pid %d failed — %s", pid, strerror(errno))
    }
}

@MainActor
public final class LiveSharedBrowserLauncher: SharedBrowserLaunching {
    public init() {}

    public func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public func launch(
        executable: String, arguments: [String], log: URL, onExit: @escaping @MainActor @Sendable (Int32) -> Void
    ) throws -> any SharedBrowserProcess {
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw LinkCError.process("could not create \(log.path) for Chrome's output")
        }
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in onExit(status) }
        }
        try process.run()
        do {
            try output.close()
        } catch {
            NSLog("[linkC browser] could not close linkC's copy of %@ — %@", log.path, String(describing: error))
        }
        return LiveSharedBrowserProcess(process)
    }

    public func runDetached(executable: String, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, given in given }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

public struct LiveSharedBrowserDevTools: SharedBrowserDevTools {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    public func pageTargets(port: Int) async throws -> [PageTarget] {
        let (data, status) = try await get("/json/list", port: port)
        guard status == 200 else { throw LinkCError.process("Chrome answered /json/list with HTTP \(status)") }
        return try Self.pageIds(in: data).map { PageTarget(id: $0) }
    }

    public func closeTarget(_ id: String, port: Int) async throws {
        let (data, status) = try await get("/json/close/\(id)", port: port)
        guard status == 200 || status == 404 else {
            throw LinkCError.process("Chrome answered /json/close/\(id) with HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// The ids of the `page` targets in a `/json/list` answer.
    static func pageIds(in data: Data) throws -> [String] {
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LinkCError.process("Chrome's /json/list is not a list of targets")
        }
        return targets.filter { $0["type"] as? String == "page" }.compactMap { $0["id"] as? String }
    }

    private func get(_ path: String, port: Int) async throws -> (Data, Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw LinkCError.process("\(path) is not a DevTools path")
        }
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct LiveSharedBrowserProcesses: SharedBrowserProcessInspecting {
    public init() {}

    public func arguments(of pid: Int32) -> [String]? {
        ProcessSnooper.arguments(of: pid)
    }

    public func parent(of pid: Int32) -> Int32? {
        ProcessSnooper.parentPid(of: pid)
    }

    public func signal(_ pid: Int32, _ signal: Int32) {
        guard kill(pid, signal) != 0, errno != ESRCH else { return }
        NSLog("[linkC browser] signal %d to pid %d failed — %s", signal, pid, strerror(errno))
    }
}
