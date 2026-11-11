import Foundation
@testable import LinkCKit

/// Model lists for tests that build an `MCPServer` or an `AppCoordinator`. Their default reads
/// `~/Library/Application Support/linkC`, which a test must never touch.
enum TestModelLists {
    /// Nothing has been listed yet: no agent has a cached list.
    static let none: @Sendable () throws -> [AgentKind: AgentModelList] = { [:] }
}
