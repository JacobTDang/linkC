import Foundation
@testable import LinkCKit

extension HookServer {
    /// A server whose status-line cache is a scratch file. The real cache is
    /// `~/Library/Application Support/linkC/claude-status-line.json`, which the installed app and
    /// `linkc-mcp` read: a test that reaches it overwrites the user's live figures with its own.
    static func forTesting(port: UInt16 = 0, maxRequestBytes: Int = 1 << 20) -> HookServer {
        HookServer(
            port: port, maxRequestBytes: maxRequestBytes,
            statusLineCacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("linkc-test-status-line-\(UUID().uuidString).json"))
    }
}
