import XCTest
@testable import LinkCKit

final class ProjectPathTests: XCTestCase {
    func testSymlinkResolvesToFolderItself() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("linkc-project-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realFolder = tempDir.appendingPathComponent("Proj")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)

        let symlink = tempDir.appendingPathComponent("link_to_proj")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFolder)

        XCTAssertEqual(ProjectPath.canonical(symlink.path), ProjectPath.canonical(realFolder.path))
    }

    func testLowercaseSpellingResolvesToTrueCasePath() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("linkc-project-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realFolder = tempDir.appendingPathComponent("Proj")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)

        let lower = tempDir.appendingPathComponent("proj").path
        guard FileManager.default.fileExists(atPath: lower) else {
            throw XCTSkip("The volume is case-sensitive; skipping case assertion")
        }

        let canonicalReal = ProjectPath.canonical(realFolder.path)
        XCTAssertTrue(canonicalReal.hasSuffix("/Proj"))
        XCTAssertEqual(ProjectPath.canonical(lower), canonicalReal)
    }

    func testUppercaseSpellingResolvesToTrueCasePath() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("linkc-project-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realFolder = tempDir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)

        let upper = tempDir.appendingPathComponent("PROJ").path
        guard FileManager.default.fileExists(atPath: upper) else {
            throw XCTSkip("The volume is case-sensitive; skipping case assertion")
        }

        let canonicalReal = ProjectPath.canonical(realFolder.path)
        XCTAssertTrue(canonicalReal.hasSuffix("/proj"))
        XCTAssertEqual(ProjectPath.canonical(upper), canonicalReal)
    }

    func testMissingPathReturnsItsStandardizedForm() {
        let missing = "/path/to/nonexistent/./folder/../folder"
        XCTAssertEqual(ProjectPath.canonical(missing), (missing as NSString).standardizingPath)
    }
}
