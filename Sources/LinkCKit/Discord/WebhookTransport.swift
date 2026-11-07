import Foundation

/// One webhook response: what the queue reads from it (spec §4.4). Header names are lowercased.
public struct WebhookResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// The seam every webhook request goes through: URLSession in the app, a script in tests.
public protocol WebhookTransport: Sendable {
    func post(_ body: Data, to url: URL) async throws -> WebhookResponse
}
