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

    /// The id of the message Discord saved: only a 200 whose JSON object has a non-empty string `id` (spec §4.4).
    public var savedMessageID: String? {
        guard status == 200 else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = json["id"] as? String,
              !id.isEmpty else {
            return nil
        }
        return id
    }
}

/// The seam every webhook request goes through: URLSession in the app, a script in tests.
public protocol WebhookTransport: Sendable {
    func post(_ body: Data, to url: URL) async throws -> WebhookResponse
}

/// The real transport: an ephemeral session, a 10 s timeout, and no redirects (a webhook that
/// redirects is not Discord's). Errors are reported by type (`describe`): a `URLError`'s
/// `userInfo` holds the URL, which is a secret.
public struct URLSessionWebhookTransport: WebhookTransport {
    public struct Failure: Error, LocalizedError {
        public let errorDescription: String?
    }

    /// A transport error by its type (and a URLError's code), never by its text, which can hold the URL.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            let code = urlError.errorCode
            let words: String? = switch urlError.code {
            case .timedOut: "the request timed out"
            case .notConnectedToInternet: "no internet connection"
            case .networkConnectionLost: "the connection was lost"
            case .cannotFindHost: "the host was not found"
            case .cannotConnectToHost: "could not connect"
            default: nil
            }
            if let words {
                return "\(words) (URLError \(code))"
            } else {
                return "URLError \(code)"
            }
        }
        return String(describing: type(of: error))
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
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
            throw Failure(errorDescription: Self.describe(error))
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
