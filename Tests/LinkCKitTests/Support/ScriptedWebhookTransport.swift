import Foundation
@testable import LinkCKit

/// A `WebhookTransport` for tests: records every request and answers from a script, oldest first.
/// Once the script runs out, every request is answered 204.
final class ScriptedWebhookTransport: WebhookTransport, @unchecked Sendable {
    struct Request {
        let url: URL
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }

        var embedTitles: [String] {
            (json["embeds"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
        }
    }

    private let lock = NSLock()
    private var script: [Result<WebhookResponse, Error>]
    private var recorded: [Request] = []

    init(_ script: [Result<WebhookResponse, Error>] = []) {
        self.script = script
    }

    var requests: [Request] { lock.withLock { recorded } }

    func post(_ body: Data, to url: URL) async throws -> WebhookResponse {
        let answer: Result<WebhookResponse, Error> = lock.withLock {
            recorded.append(Request(url: url, body: body))
            return script.isEmpty ? .success(WebhookResponse(status: 204)) : script.removeFirst()
        }
        return try answer.get()
    }
}
