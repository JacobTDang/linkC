import Darwin
import Foundation

/// The project folders where linkC's MCP server (`linkc-mcp`) is running. Every agent CLI starts its own
/// server in the folder it works in, wherever it runs: in a linkC session, in a shell the user typed it
/// into, or in another terminal app. Each server registers its folder for its lifetime, one file per
/// process, so linkC can serve a folder where it has no session of its own: watch its inbox, deliver its
/// tasks, and launch workers for them.
public struct MCPWorkspaceRegistry: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The registry in linkC's own Application Support folder, shared by the app and every server.
    public static var applicationSupport: MCPWorkspaceRegistry {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
            .appendingPathComponent("mcp-workspaces", isDirectory: true)
        return MCPWorkspaceRegistry(directory: dir)
    }

    /// When a process started, as the kernel records it. With its pid it names one process: a pid is
    /// reused, but never with the same start time.
    public struct ProcessStart: Codable, Equatable, Sendable {
        public let seconds: Int64
        public let microseconds: Int32

        public init(seconds: Int64, microseconds: Int32) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    /// A registered server: its pid and when its process started.
    public struct Server: Codable, Equatable, Sendable {
        public let pid: Int32
        public let startedAt: ProcessStart

        public init(pid: Int32, startedAt: ProcessStart) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    private struct Entry: Codable {
        let pid: Int32
        let startedAt: ProcessStart
        let workspace: String
    }

    private func entryURL(pid: Int32) -> URL {
        directory.appendingPathComponent("\(pid).json", isDirectory: false)
    }

    /// Records that the server process serves `workspace`, until `unregister(pid:)`.
    public func register(workspace: String, pid: Int32, startedAt: ProcessStart) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(pid: pid, startedAt: startedAt, workspace: workspace))
            .write(to: entryURL(pid: pid), options: .atomic)
    }

    /// Registers the calling process. Its kernel start time keeps the entry tied to this process even
    /// if its executable is replaced or its pid is later reused.
    public func registerCurrentProcess(workspace: String) throws {
        let pid = getpid()
        guard let startedAt = Self.startTime(of: pid) else {
            throw LinkCError.server("the start time of pid \(pid) could not be read")
        }
        try register(workspace: workspace, pid: pid, startedAt: startedAt)
    }

    /// Removes the entry; an entry already gone (linkC removed it) is fine.
    public func unregister(pid: Int32) throws {
        do {
            try FileManager.default.removeItem(at: entryURL(pid: pid))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// The canonical folders of the servers still running. The entry of a server that is gone (killed
    /// before it could unregister) is removed; corrupt entries are logged and removed.
    public func liveWorkspaces(isRunning: (Server) -> Bool = MCPWorkspaceRegistry.isRunning) -> Set<String> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            NSLog("[linkC] MCP workspace registry %@ can't be listed — %@", directory.path, String(describing: error))
            return []
        }
        var folders: Set<String> = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                NSLog("[linkC] MCP workspace registry: entry %@ can't be read — %@", name, String(describing: error))
                continue
            }
            let entry: Entry
            do {
                entry = try JSONDecoder().decode(Entry.self, from: data)
            } catch {
                NSLog("[linkC] MCP workspace registry: entry %@ is corrupt, removing it — %@", name, String(describing: error))
                remove(url, ifStill: data)
                continue
            }
            guard isRunning(Server(pid: entry.pid, startedAt: entry.startedAt)) else {
                remove(url, ifStill: data)
                continue
            }
            folders.insert(ProjectPath.canonical(entry.workspace))
        }
        return folders
    }

    /// Removes only the entry that was inspected; a replacement for a process reusing the pid stays.
    private func remove(_ url: URL, ifStill data: Data) {
        do {
            guard try Data(contentsOf: url) == data else { return }
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return
        } catch {
            NSLog("[linkC] MCP workspace registry: could not remove %@ — %@", url.path, String(describing: error))
        }
    }

    /// When `pid` started, as recorded by the kernel.
    public static func startTime(of pid: Int32) -> ProcessStart? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStart(seconds: Int64(info.pbi_start_tvsec), microseconds: Int32(info.pbi_start_tvusec))
    }

    /// Whether the process that registered this server is still running.
    public static func isRunning(_ server: Server) -> Bool {
        startTime(of: server.pid) == server.startedAt
    }
}
