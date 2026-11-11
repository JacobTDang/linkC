import XCTest
@testable import LinkCKit

/// An error whose text holds a webhook URL, as a URLError's can.
private struct LeakyError: Error, LocalizedError {
    var errorDescription: String? { "failed for https://discord.com/api/webhooks/1/secret-token" }
}

/// The real transport reports a failure by its type, never by its text, which can hold the webhook URL (spec §4.4).
final class WebhookTransportTests: XCTestCase {
    func testAURLErrorIsNamedByItsCode() {
        let url = URL(string: "https://discord.com/api/webhooks/1/secret-token")!
        let timedOut = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString,
        ])
        XCTAssertEqual(URLSessionWebhookTransport.describe(timedOut), "the request timed out (URLError -1001)")
        XCTAssertEqual(URLSessionWebhookTransport.describe(URLError(.notConnectedToInternet)), "no internet connection (URLError -1009)")
        XCTAssertEqual(URLSessionWebhookTransport.describe(URLError(.networkConnectionLost)), "the connection was lost (URLError -1005)")
        XCTAssertEqual(URLSessionWebhookTransport.describe(URLError(.cannotFindHost)), "the host was not found (URLError -1003)")
        XCTAssertEqual(URLSessionWebhookTransport.describe(URLError(.cannotConnectToHost)), "could not connect (URLError -1004)")
        XCTAssertEqual(URLSessionWebhookTransport.describe(URLError(.secureConnectionFailed)), "URLError -1200")
    }

    func testAnyOtherErrorIsNamedByItsType() {
        XCTAssertEqual(URLSessionWebhookTransport.describe(LeakyError()), "LeakyError")
    }
}
