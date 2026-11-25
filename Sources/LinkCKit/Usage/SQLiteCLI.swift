import Foundation

/// Reads an agent's SQLite database through macOS's own `/usr/bin/sqlite3`, read-only, so linkC
/// links no database library. Runs synchronously: call it off the main actor.
public enum SQLiteCLI {
    public static let executable = "/usr/bin/sqlite3"

    public enum Open: Sendable {
        /// Read-only, seeing what a writer has committed, its write-ahead log included.
        case readOnly
        /// The file is read as it is, with no lock and no log: for a database another process holds
        /// in a way a read-only open is refused.
        case immutable
    }

    /// The rows `query` returns, decoded by column name. A blob column must be selected as
    /// `hex(...)`: the CLI's JSON would print its raw bytes. Throws `LinkCError.process` with
    /// sqlite3's own reason when the file cannot be opened or the query fails.
    public static func rows<Row: Decodable>(_ type: Row.Type, in path: String, query: String,
                                           open: Open = .readOnly, timeout: TimeInterval = 3) throws -> [Row] {
        let args: [String]
        switch open {
        case .readOnly:
            args = ["-readonly", "-json", path, query]
        case .immutable:
            args = ["-json", URL(fileURLWithPath: path).absoluteString + "?immutable=1", query]
        }
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
}
