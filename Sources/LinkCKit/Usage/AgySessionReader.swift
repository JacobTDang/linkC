import Foundation

/// Reads an Antigravity CLI (agy) session from its conversation database,
/// `<agy folder>/conversations/<conversation id>.db`. agy does not hold that file open; it holds
/// `<agy folder>/presence/<conversation id>.lock` open for as long as it runs the conversation, and
/// the id in that name ties the session to its database exactly. A session whose process tree holds
/// no such lock, or more than one, reads as nothing.
public struct AgySessionReader: SessionLiveReader {
    public init() {}

    public func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
        guard let database = Self.conversationDatabase(among: target.openFiles),
              FileManager.default.fileExists(atPath: database)
        else { return SessionLiveDetail() }
        return SessionLiveDetail(contextPercent: try Self.contextPercent(inDatabaseAt: database))
    }

    /// The database of the one conversation whose lock is open; nil for none or for several.
    static func conversationDatabase(among openFiles: [String]) -> String? {
        var databases = Set<String>()
        for path in openFiles {
            let url = URL(fileURLWithPath: path)
            let parts = url.pathComponents
            guard url.pathExtension == "lock", parts.count >= 3,
                  parts[parts.count - 2] == "presence", parts[parts.count - 3] == "antigravity-cli",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { continue }
            let folder = url.deletingLastPathComponent().deletingLastPathComponent()
            databases.insert(folder.appendingPathComponent("conversations/\(id.uuidString.lowercased()).db").path)
        }
        return databases.count == 1 ? databases.first : nil
    }

    private struct Row: Decodable { let data: String }

    /// How full the conversation's context window is. The row of `gen_metadata` with the highest
    /// `idx` is a protobuf whose message at 1.9.10 holds the tokens used (field 1) and the window
    /// (field 4). Nil while no row records them. agy holds the file in a way a read-only open is
    /// refused, so it is read as it is, with no lock.
    static func contextPercent(inDatabaseAt path: String) throws -> Int? {
        let rows = try SQLiteCLI.rows(Row.self, in: path, query: "select hex(data) as data from gen_metadata order by idx desc limit 1",
                                      open: .immutable)
        guard let row = rows.first else { return nil }
        guard let bytes = SQLiteCLI.bytes(fromHex: row.data) else {
            throw LinkCError.parse("the latest gen_metadata row of \(path) is not hex")
        }
        let context = try ProtobufWire.fields(at: [1, 9, 10], in: bytes)
        return SessionLiveDetail.contextPercent(used: context?.varint(1), window: context?.varint(4))
    }
}
