import CryptoKit
import Foundation

@MainActor
public protocol SharedBrowserProcess: AnyObject {
    func stop()
}

@MainActor
public protocol SharedBrowserLaunching: AnyObject {
    func isExecutable(_ path: String) -> Bool
    func launch(executable: String, arguments: [String], profileDirectory: URL) throws -> any SharedBrowserProcess
}

@MainActor
public protocol SharedBrowserTabClosing: AnyObject {
    func closePinnedTab(port: Int, sessionName: String) throws
}

@MainActor
public final class LiveSharedBrowserTabCloser: SharedBrowserTabClosing {
    private let executable: String

    public init(
        executable: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/agent-browser").path
    ) {
        self.executable = executable
    }

    public func closePinnedTab(port: Int, sessionName: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw LinkCError.process("agent-browser is not installed at \(executable)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--cdp", String(port), "--session", sessionName, "--pin-tab", "tab", "close", "--json"
        ]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinkCError.process(detail.isEmpty ? "agent-browser could not close the pinned tab" : detail)
        }
    }
}

@MainActor
public final class LiveSharedBrowserProcess: SharedBrowserProcess {
    private let process: Process

    init(_ process: Process) { self.process = process }

    public func stop() {
        if process.isRunning { process.terminate() }
    }
}

@MainActor
public final class LiveSharedBrowserLauncher: SharedBrowserLaunching {
    public init() {}

    public func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public func launch(
        executable: String, arguments: [String], profileDirectory: URL
    ) throws -> any SharedBrowserProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return LiveSharedBrowserProcess(process)
    }
}

/// Owns one headless Chrome per canonical project and gives every linkC session its own pinned tab.
@MainActor
public final class SharedBrowser {
    public static let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private struct Instance {
        let process: any SharedBrowserProcess
        let port: Int
        var sessions: Set<String>
    }

    private let applicationSupport: URL
    private let chromePath: String
    private let launcher: any SharedBrowserLaunching
    private let tabCloser: any SharedBrowserTabClosing
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let report: (String) -> Void
    private var instances: [String: Instance] = [:]
    private var sessionProjects: [String: String] = [:]
    private var reportedFailures: Set<String> = []

    public init(
        applicationSupport: URL,
        chromePath: String = SharedBrowser.chromePath,
        launcher: any SharedBrowserLaunching = LiveSharedBrowserLauncher(),
        tabCloser: any SharedBrowserTabClosing = LiveSharedBrowserTabCloser(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        report: @escaping (String) -> Void = { _ in }
    ) {
        self.applicationSupport = applicationSupport
        self.chromePath = chromePath
        self.launcher = launcher
        self.tabCloser = tabCloser
        self.now = now
        self.sleep = sleep
        self.report = report
    }

    public nonisolated static func sessionEnvironment(port: Int, sessionId: String) -> [String: String] {
        [
            "AGENT_BROWSER_CDP": String(port),
            "AGENT_BROWSER_PIN_TAB": "1",
            "AGENT_BROWSER_SESSION": "linkc-\(sessionId)"
        ]
    }

    public func environment(projectPath: String, sessionId: String) -> [String: String]? {
        let project = ProjectPath.canonical(projectPath)
        if var instance = instances[project] {
            instance.sessions.insert(sessionId)
            instances[project] = instance
            sessionProjects[sessionId] = project
            return Self.sessionEnvironment(port: instance.port, sessionId: sessionId)
        }
        do {
            let instance = try start(project: project, sessionId: sessionId)
            instances[project] = instance
            sessionProjects[sessionId] = project
            return Self.sessionEnvironment(port: instance.port, sessionId: sessionId)
        } catch {
            if reportedFailures.insert(project).inserted {
                report("Shared browser unavailable: \(error.localizedDescription). This session started without browser sharing.")
            }
            return nil
        }
    }

    public func release(sessionId: String) {
        guard let project = sessionProjects.removeValue(forKey: sessionId), var instance = instances[project] else { return }
        do {
            try tabCloser.closePinnedTab(port: instance.port, sessionName: "linkc-\(sessionId)")
        } catch {
            if reportedFailures.insert("tab:\(project)").inserted {
                report("Shared browser tab cleanup failed: \(error.localizedDescription)")
            }
        }
        instance.sessions.remove(sessionId)
        if instance.sessions.isEmpty {
            instance.process.stop()
            instances.removeValue(forKey: project)
        } else {
            instances[project] = instance
        }
    }

    public func stopAll() {
        for instance in instances.values { instance.process.stop() }
        instances.removeAll()
        sessionProjects.removeAll()
    }

    private func start(project: String, sessionId: String) throws -> Instance {
        guard launcher.isExecutable(chromePath) else {
            throw LinkCError.process("Google Chrome is not installed at \(chromePath)")
        }
        let profile = profileDirectory(for: project)
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let portFile = profile.appendingPathComponent("DevToolsActivePort")
            try? FileManager.default.removeItem(at: portFile)
            let args = [
                "--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(profile.path)",
                "--no-first-run", "--no-default-browser-check"
            ]
            let process = try launcher.launch(executable: chromePath, arguments: args, profileDirectory: profile)
            do {
                let port = try waitForPort(at: portFile)
                return Instance(process: process, port: port, sessions: [sessionId])
            } catch {
                process.stop()
                throw error
            }
        } catch let error as LinkCError {
            throw error
        } catch {
            throw LinkCError.process("Google Chrome could not start — \(error.localizedDescription)")
        }
    }

    private func waitForPort(at file: URL) throws -> Int {
        let deadline = now().addingTimeInterval(5)
        repeat {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let first = text.split(whereSeparator: \.isNewline).first,
               let port = Int(first), (1...65_535).contains(port) {
                return port
            }
            sleep(0.05)
        } while now() < deadline
        throw LinkCError.process("Google Chrome did not publish a DevTools port within 5 seconds")
    }

    private func profileDirectory(for project: String) -> URL {
        let digest = SHA256.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined()
        return applicationSupport.appendingPathComponent("browser", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }
}
