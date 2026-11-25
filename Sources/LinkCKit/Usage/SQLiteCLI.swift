import Darwin
import Foundation

/// Reads an agent's SQLite database through macOS's own `/usr/bin/sqlite3`, read-only, so linkC
/// links no database library. Runs synchronously: call it off the main actor.
public enum SQLiteCLI {
    public static let executable = "/usr/bin/sqlite3"

    public enum Open: Sendable {
        /// Read-only, seeing what a writer has committed, its write-ahead log included. Refused for a
        /// WAL database with no `-shm` beside it: a read-only open needs that index of the log and
        /// cannot make one.
        case readOnly
        /// A clone of the file and its write-ahead log, made in a new folder under the given one, read
        /// with a normal open and removed after. Sees the log a writer has not checkpointed, and works
        /// with no `-shm` there. APFS clones cost next to nothing.
        case clone(in: URL)
    }

    /// The bytes a `hex(blob)` column spells, or nil when it is not whole hex digit pairs.
    public static func bytes(fromHex hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The rows `query` returns, decoded by column name. A blob column must be selected as
    /// `hex(...)`: the CLI's JSON would print its raw bytes. Throws `LinkCError.process` with
    /// sqlite3's own reason when the file cannot be opened or the query fails.
    public static func rows<Row: Decodable>(_ type: Row.Type, in path: String, query: String,
                                           open: Open = .readOnly, timeout: TimeInterval = 3) throws -> [Row] {
        switch open {
        case .readOnly:
            return try run(Row.self, args: ["-readonly", "-json", path, query], reading: path, timeout: timeout)
        case .clone(let scratch):
            return try withClone(of: path, in: scratch) { clone in
                try run(Row.self, args: ["-json", clone, query], reading: path, timeout: timeout)
            }
        }
    }

    private static func run<Row: Decodable>(_ type: Row.Type, args: [String], reading path: String, timeout: TimeInterval) throws -> [Row] {
        let result: ProcessResult
        do {
            result = try LiveProcessRunner.runCapturingSync(executable: executable, args: args, cwd: nil, timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("sqlite3 timed out after \(seconds)s reading \(path)")
        }
        guard result.status == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinkCError.process("sqlite3 could not read \(path): \(reason.isEmpty ? "it exited \(result.status)" : reason)")
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // No rows print nothing at all.
        guard !output.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([Row].self, from: Data(output.utf8))
        } catch {
            throw LinkCError.process("sqlite3's rows from \(path) are not the shape expected: \(error)")
        }
    }

    // MARK: - Cloning

    /// Runs `body` on a clone of the database at `path` and its write-ahead log, in a new folder under
    /// `scratch` that is removed after. The log is cloned first: should the writer checkpoint between
    /// the two clones, the file cloned after it already holds what the log does, and the log replays
    /// over it to the same pages. The `-shm` is not cloned: it indexes the log as the writer has it
    /// now, which may be ahead of the clone, and with none the clone's first open rebuilds the index
    /// from the log it has.
    static func withClone<T>(of path: String, in scratch: URL, _ body: (String) throws -> T) throws -> T {
        let folder = scratch.appendingPathComponent("linkc-sqlite-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let clone = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        let outcome = Result { () throws -> T in
            // A log gone by now was checkpointed into the file as its writer closed.
            _ = try cloneIfThere(path + "-wal", to: clone + "-wal")
            guard try cloneIfThere(path, to: clone) else {
                throw LinkCError.process("sqlite3 could not read \(path): there is no such file")
            }
            return try body(clone)
        }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw LinkCError.process("the clone of \(path) at \(folder.path) could not be removed: \(error.localizedDescription)")
        }
        return try outcome.get()
    }

    /// Clones `source` to `destination` (a copy where the volume cannot clone); false when there is
    /// no `source`.
    private static func cloneIfThere(_ source: String, to destination: String) throws -> Bool {
        guard copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 else { return true }
        let code = errno
        if code == ENOENT { return false }
        throw LinkCError.process("\(source) could not be cloned: \(String(cString: strerror(code)))")
    }
}
