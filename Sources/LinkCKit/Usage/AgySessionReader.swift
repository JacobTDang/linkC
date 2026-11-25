import Foundation

/// Reads an Antigravity CLI (agy) session from its conversation database,
/// `<agy folder>/conversations/<conversation id>.db`. agy holds
/// `<agy folder>/presence/<conversation id>.lock` open for as long as it runs the conversation, and
/// the id in that name ties the session to its database exactly. A session whose process tree holds
/// no such lock, or more than one, reads as nothing.
///
/// agy keeps the database in WAL mode and has it open while it works on the conversation, so the
/// newest rows may be in `<id>.db-wal` alone; between turns it closes it and deletes the `-wal` and
/// `-shm`. A read-only open is refused with no `-shm`, and an immutable one ignores the log, so the
/// database is read from a clone of it and its log.
public struct AgySessionReader: SessionLiveReader {
    /// Where each read's clone of the database is made, and removed from after.
    private let scratch: URL

    public init(scratch: URL = FileManager.default.temporaryDirectory) {
        self.scratch = scratch
    }

    public func sources(of target: LiveSessionTarget) throws -> [String] {
        Self.conversationDatabase(among: target.openFiles).map { [$0, $0 + "-wal"] } ?? []
    }

    public func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
        guard let database = Self.conversationDatabase(among: target.openFiles),
              FileManager.default.fileExists(atPath: database)
        else { return SessionLiveDetail() }
        return SessionLiveDetail(contextPercent: try Self.contextPercent(inDatabaseAt: database, scratch: scratch))
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
    /// (field 4). Nil while no row records them. The clone is made under `scratch`.
    static func contextPercent(inDatabaseAt path: String, scratch: URL) throws -> Int? {
        let rows = try SQLiteCLI.rows(Row.self, in: path, query: "select hex(data) as data from gen_metadata order by idx desc limit 1",
                                      open: .clone(in: scratch))
        guard let row = rows.first else { return nil }
        guard let bytes = SQLiteCLI.bytes(fromHex: row.data) else {
            throw LinkCError.parse("the latest gen_metadata row of \(path) is not hex")
        }
        let context = try ProtobufWire.fields(at: [1, 9, 10], in: bytes)
        return SessionLiveDetail.contextPercent(used: context?.varint(1), window: context?.varint(4))
    }
}
