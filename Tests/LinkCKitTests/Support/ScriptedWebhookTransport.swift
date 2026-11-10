import Foundation
@testable import LinkCKit

extension WebhookResponse {
    /// What Discord answers a post with `wait=true` once it saved the message.
    static func saved(id: String = "1", headers: [String: String] = [:]) -> WebhookResponse {
        WebhookResponse(status: 200, headers: headers, body: Data(#"{"id":"\#(id)","type":0}"#.utf8))
    }
}

/// A `WebhookTransport` for tests: records every request and answers from a script, oldest first.
/// Once the script runs out, every request is answered as a saved message.
final class ScriptedWebhookTransport: WebhookTransport, @unchecked Sendable {
    struct Request {
        let url: URL
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }

        /// Every text display's content, in order, nested ones included.
        var texts: [String] {
            func walk(_ components: [[String: Any]]) -> [String] {
                components.flatMap { component -> [String] in
                    let own = component["type"] as? Int == 10 ? [component["content"] as? String ?? ""] : []
                    return own + walk(component["components"] as? [[String: Any]] ?? [])
                }
            }
            return walk(json["components"] as? [[String: Any]] ?? [])
        }

        /// The first text display: a card's or a digest page's headline.
        var headline: String? { texts.first }
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
            return script.isEmpty ? .success(.saved()) : script.removeFirst()
        }
        return try answer.get()
    }
}
