import CryptoKit
import Foundation

/// Reads a Cursor Agent or Grok session from the chat the agent keeps in
/// `<config folder>/chats/<md5 of the session's folder>/<chat id>/store.db`. Grok is the Cursor CLI
/// run with its own config folder, so the format is one. The running agent holds that `store.db`
/// open, which ties the session to its chat exactly: a session whose process tree holds none open
/// reads as nothing.
public struct CursorSessionReader: SessionLiveReader {
    private let transcriptRoots: [URL]
    private let tailBytes: Int

    /// `transcriptRoots` are the `projects` folders that hold chats' transcripts. Grok keeps its
    /// transcripts in Cursor's, so both are searched. `tailBytes` is how much of a transcript's end
    /// is read for the step.
    public init(transcriptRoots: [URL] = CursorSessionReader.defaultTranscriptRoots, tailBytes: Int = 1 << 20) {
        self.transcriptRoots = transcriptRoots
        self.tailBytes = tailBytes
    }

    public static var defaultTranscriptRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".cursor", ".cursor-grok"].map { home.appendingPathComponent("\($0)/projects") }
    }

    public func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
        guard let store = Self.chatStore(among: target) else { return SessionLiveDetail() }
        let chatId = URL(fileURLWithPath: store).deletingLastPathComponent().lastPathComponent
        var step: String?
        if let transcript = try transcript(ofChat: chatId) {
            step = try CursorTranscriptStep.label(inTranscriptAt: transcript, tailBytes: tailBytes)
        }
        return SessionLiveDetail(contextPercent: try Self.contextPercent(inStoreAt: store), step: step)
    }

    /// `<root>/<a folder>/agent-transcripts/<chat id>/<chat id>.jsonl`. The folder is named for the
    /// session's folder in a way that shortens long names with a hash, so the chat id finds it
    /// instead. Nil while the agent has not written one.
    private func transcript(ofChat chatId: String) throws -> URL? {
        let files = FileManager.default
        for root in transcriptRoots where files.fileExists(atPath: root.path) {
            for folder in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let candidate = folder.appendingPathComponent("agent-transcripts/\(chatId)/\(chatId).jsonl")
                if files.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    // MARK: - Finding the chat

    /// The chat store the session holds open. Several open at once are told apart by the folder
    /// they are for; when that does not leave exactly one, the session cannot be matched.
    static func chatStore(among target: LiveSessionTarget) -> String? {
        let stores = Set(target.openFiles.filter(isChatStore)).sorted()
        guard stores.count > 1 else { return stores.first }
        let folder = md5(target.cwd)
        let mine = stores.filter { URL(fileURLWithPath: $0).pathComponents.dropLast(2).last == folder }
        return mine.count == 1 ? mine[0] : nil
    }

    /// `…/chats/<folder hash>/<chat id>/store.db`, not its write-ahead log or shared-memory file.
    private static func isChatStore(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents
        return parts.count >= 4 && parts[parts.count - 1] == "store.db" && parts[parts.count - 4] == "chats"
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Context

    private struct MetaRow: Decodable { let value: String }
    private struct BlobRow: Decodable { let data: String }

    /// How full the chat's context window is. The `meta` row for key 0 is hex-encoded JSON naming
    /// `latestRootBlobId`; that blob's field 5 holds the tokens used (1) and the window (2). Nil
    /// while the chat records no usage yet: no turn run, or the usage missing its tokens or window.
    static func contextPercent(inStoreAt path: String) throws -> Int? {
        let metaRows = try SQLiteCLI.rows(MetaRow.self, in: path, query: "select value from meta where key = '0'")
        guard let meta = metaRows.first else { throw LinkCError.parse("\(path) has no meta row 0") }
        guard let json = SQLiteCLI.bytes(fromHex: meta.value) else {
            throw LinkCError.parse("meta row 0 of \(path) is not hex")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw LinkCError.parse("meta row 0 of \(path) is not JSON")
        }
        guard let rootId = object["latestRootBlobId"] as? String else {
            throw LinkCError.parse("meta row 0 of \(path) has no latestRootBlobId")
        }
        guard !rootId.isEmpty else { return nil }
        // The id goes into the query, so it must be nothing but what an id is made of.
        guard rootId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw LinkCError.parse("latestRootBlobId in \(path) is not a blob id")
        }
        let blobRows = try SQLiteCLI.rows(BlobRow.self, in: path, query: "select hex(data) as data from blobs where id = '\(rootId)'")
        guard let blob = blobRows.first, let bytes = SQLiteCLI.bytes(fromHex: blob.data) else {
            throw LinkCError.parse("root blob \(rootId) is not in \(path)")
        }
        let usage = try ProtobufWire.fields(at: [5], in: bytes)
        return SessionLiveDetail.contextPercent(used: usage?.varint(1), window: usage?.varint(2))
    }
}
