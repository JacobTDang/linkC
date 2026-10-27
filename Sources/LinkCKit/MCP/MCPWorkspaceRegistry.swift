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

    private struct Entry: Codable {
        let pid: Int32
        let workspace: String
    }

    private func entryURL(pid: Int32) -> URL {
        directory.appendingPathComponent("\(pid).json", isDirectory: false)
    }

    /// Records that the server with `pid` serves `workspace`, until `unregister(pid:)`.
    public func register(workspace: String, pid: Int32) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(pid: pid, workspace: workspace)).write(to: entryURL(pid: pid), options: .atomic)
    }

    /// Removes the server's entry. A server that never registered has nothing to remove.
    public func unregister(pid: Int32) throws {
        let url = entryURL(pid: pid)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The canonical folders of the servers still running. The entry of a server that is gone (killed
    /// before it could unregister) is removed; an entry that can't be read is logged and removed.
    public func liveWorkspaces(isRunning: (Int32) -> Bool = MCPWorkspaceRegistry.isMCPServerRunning) -> Set<String> {
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
            let entry: Entry
            do {
                entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            } catch {
                NSLog("[linkC] MCP workspace registry: entry %@ can't be read, removing it — %@", name, String(describing: error))
                remove(url)
                continue
            }
            guard isRunning(entry.pid) else {
                remove(url)
                continue
            }
            folders.insert(ProjectPath.canonical(entry.workspace))
        }
        return folders
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("[linkC] MCP workspace registry: could not remove %@ — %@", url.path, String(describing: error))
        }
    }

    /// Whether `pid` is a running `linkc-mcp`. After a server dies its pid can be handed to an unrelated
    /// process, so the executable is checked as well as the pid.
    public static func isMCPServerRunning(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
        return (path as NSString).lastPathComponent == "linkc-mcp"
    }
}
