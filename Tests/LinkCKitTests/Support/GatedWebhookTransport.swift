import Foundation
@testable import LinkCKit

/// A `WebhookTransport` for tests that holds each request until `release(with:)`: what a request still
/// in flight looks like.
final class GatedWebhookTransport: WebhookTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<WebhookResponse, Never>] = []
    private var count = 0

    /// How many requests have been made, answered or not.
    var requests: Int { lock.withLock { count } }

    func post(_ body: Data, to url: URL) async throws -> WebhookResponse {
        await withCheckedContinuation { continuation in
            lock.withLock {
                count += 1
                waiting.append(continuation)
            }
        }
    }

    /// Answers every request still waiting with `response`.
    func release(with response: WebhookResponse) {
        let held = lock.withLock { () -> [CheckedContinuation<WebhookResponse, Never>] in
            defer { waiting.removeAll() }
            return waiting
        }
        held.forEach { $0.resume(returning: response) }
    }
}
