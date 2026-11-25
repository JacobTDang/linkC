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
