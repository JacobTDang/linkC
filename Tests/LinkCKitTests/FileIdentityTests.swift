import XCTest
import Darwin
@testable import LinkCKit

/// `FileIdentity.read` hands back a file's bytes together with the identity `InboxReadCache` will
/// later compare a path against. The pair has to describe one file: an identity that belongs to
/// some other file than the bytes would let the cache serve those bytes for as long as the other
/// file's identity holds.
final class FileIdentityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-file-identity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private var file: String {
        tempDir.appendingPathComponent("state.json").path
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private struct NotThere: Error {}

    private func probedIdentity(_ path: String) throws -> FileIdentity {
        guard case .present(let identity) = try FileIdentity.probe(path) else { throw NotThere() }
        return identity
    }

    /// The race the descriptor closes: another process renames a new file over the path after the
    /// identity was taken and before the bytes are read.
    func testTheIdentityAndTheBytesBelongToTheSameFileWhenThePathIsReplacedMidRead() throws {
        try write("old contents", to: file)
        let oldIdentity = try probedIdentity(file)
        let replacement = tempDir.appendingPathComponent("state.tmp").path
        try write("new contents, longer than the old ones", to: replacement)

        let read = try XCTUnwrap(try FileIdentity.read(file, beforeReading: {
            XCTAssertEqual(rename(replacement, file), 0)
        }))

        XCTAssertEqual(String(decoding: read.data, as: UTF8.self), "old contents")
        XCTAssertEqual(read.identity, oldIdentity, "the identity describes the file the bytes came from")
        XCTAssertNotEqual(try probedIdentity(file), read.identity, "the path now holds a different file")
    }

    /// The identity must be taken BEFORE the bytes are read. An in-place rewrite at that moment
    /// then leaves an identity older than the bytes, so the next probe differs and the cache reads
    /// again; stat-ing after the read would stamp whatever bytes were read with the newer identity.
    func testTheIdentityIsTakenBeforeTheBytesAreRead() throws {
        try write("first", to: file)

        let read = try XCTUnwrap(try FileIdentity.read(file, beforeReading: {
            let handle = FileHandle(forWritingAtPath: self.file)!
            handle.seekToEndOfFile()
            handle.write(Data(" and more".utf8))
            handle.closeFile()
        }))

        XCTAssertEqual(String(decoding: read.data, as: UTF8.self), "first and more")
        XCTAssertNotEqual(read.identity, try probedIdentity(file),
                          "an identity taken after the rewrite would match the probe and hide it")
    }

    /// A cache hit compares a path probe against the identity a read returned, so the two must be
    /// built the same way.
    func testAReadAndAProbeAgreeOnAnUnchangedFile() throws {
        try write("contents", to: file)

        let read = try XCTUnwrap(try FileIdentity.read(file))

        XCTAssertEqual(read.data, Data("contents".utf8))
        XCTAssertEqual(read.identity, try probedIdentity(file))
    }

    func testAnEmptyFileReadsAsEmptyBytes() throws {
        try write("", to: file)

        let read = try XCTUnwrap(try FileIdentity.read(file))

        XCTAssertTrue(read.data.isEmpty)
    }

    func testAMissingFileAndAMissingDirectoryReadAsNil() throws {
        XCTAssertNil(try FileIdentity.read(file))
        XCTAssertNil(try FileIdentity.read(tempDir.appendingPathComponent("no-such-dir/state.json").path))
        try write("a plain file", to: file)
        XCTAssertNil(try FileIdentity.read(file + "/below-a-file"))
    }

    func testAFileThatCannotBeOpenedThrowsInsteadOfReadingAsMissing() throws {
        try write("contents", to: file)
        XCTAssertEqual(chmod(file, 0), 0)
        defer { chmod(file, 0o600) }

        XCTAssertThrowsError(try FileIdentity.read(file))
    }
}
