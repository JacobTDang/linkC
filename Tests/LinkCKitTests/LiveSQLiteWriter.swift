import Foundation
@testable import LinkCKit

/// A `sqlite3` process that keeps a database open, as a running agent does. In WAL mode with
/// `wal_autocheckpoint=0`, what it writes stays in `<db>-wal` and never reaches the database file
/// until it checkpoints or closes.
final class LiveSQLiteWriter {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: SQLiteCLI.executable)
        process.arguments = ["-init", "/dev/null", "-batch", path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    /// Runs `sql` and returns once sqlite3 has done it. Throws what sqlite3 said when a statement failed.
    func run(_ sql: String) throws {
        let marker = "linkc-writer-done-\(UUID().uuidString)"
        try input.fileHandleForWriting.write(contentsOf: Data((sql + "\nselect '\(marker)';\n").utf8))
        var said = ""
        while !said.contains(marker) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw Failure(description: "sqlite3 exited before it ran: \(said)") }
            said += String(decoding: chunk, as: UTF8.self)
        }
        if said.contains("Error") { throw Failure(description: "sqlite3 refused: \(said)") }
    }

    /// Closes the database, which checkpoints the log into the file.
    func close() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
