import XCTest
import Darwin
@testable import LinkCKit

/// Replaces `inbox.json` the way another process does (`linkc-mcp`, an older linkC): a temp file
/// renamed over it. Nothing goes through `InboxStore`, so nothing in the test's own process is
/// told the file changed.
enum ForeignInboxWriter {
    static func replace(_ inbox: Inbox, in store: InboxStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = store.inboxURL.deletingLastPathComponent().appendingPathComponent("inbox.tmp.\(UUID().uuidString)")
        try encoder.encode(inbox).write(to: tmp)
        XCTAssertEqual(rename(tmp.path, store.inboxURL.path), 0, file: file, line: line)
    }
}
