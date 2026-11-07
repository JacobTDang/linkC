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

/// The real transport: an ephemeral session, a 10 s timeout, and no redirects (a webhook that
/// redirects is not Discord's). Errors are reported by their description only: a `URLError`'s
/// `userInfo` holds the URL, which is a secret.
public struct URLSessionWebhookTransport: WebhookTransport {
    public struct Failure: Error, LocalizedError {
        public let errorDescription: String?
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    public func post(_ body: Data, to url: URL) async throws -> WebhookResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(errorDescription: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(errorDescription: "the answer was not HTTP")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return WebhookResponse(status: http.statusCode, headers: headers, body: data)
    }
}
