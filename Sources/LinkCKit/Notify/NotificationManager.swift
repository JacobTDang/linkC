import Foundation
import UserNotifications

/// Delivery seam for `NotificationManager` — the only way it reaches the outside world.
/// Test code supplies a `RecordingSink`; the running app supplies `UNNotificationSink`.
public protocol NotificationSink: Sendable {
    func deliver(id: String, title: String, body: String)
}

/// Wraps `UNUserNotificationCenter`. Everything that touches the real notification
/// center lives here, isolated from `NotificationManager`'s testable logic.
///
/// Not exercised by unit tests: `swift test` runs outside a proper app bundle, and
/// `UNUserNotificationCenter` requires one — these paths are manually verified instead
/// (see NotifyTests.swift and the task report).
public final class UNNotificationSink: NSObject, NotificationSink, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let sessionIdUserInfoKey = "linkcSessionId"

    private let center: UNUserNotificationCenter

    /// Invoked off the main actor — `UNUserNotificationCenterDelegate` callbacks aren't
    /// actor-isolated — with the session id carried in the notification's `userInfo`.
    /// Wired up by `NotificationManager`; not part of the public seam.
    var onActivate: (@Sendable (String) -> Void)?

    public override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    public func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.sessionIdUserInfoKey: id]
        // nil trigger => deliver immediately.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                // deliver() can't throw (it's the public seam NotificationManager depends
                // on), so failures are logged rather than swallowed silently.
                NSLog("linkC: failed to deliver notification for session %@: %@", id, String(describing: error))
            }
        }
    }

    /// Requests `.alert`/`.sound` authorization from the user.
    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            NSLog("linkC: notification authorization request failed: %@", String(describing: error))
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo[Self.sessionIdUserInfoKey] as? String {
            onActivate?(id)
        }
        completionHandler()
    }

    /// Without this, macOS suppresses the banner/sound while linkC — a backgrounded
    /// menu-bar utility that is always "foreground" in the sense UN cares about — is
    /// running, which is the only time it would ever post one.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Turns a session's new state into notification copy, dedupes rapid repeats of the
/// same (session, state), and hands delivery off to a `NotificationSink`.
@MainActor
public final class NotificationManager {
    private let sink: NotificationSink
    private let unSink: UNNotificationSink?
    private let now: () -> Date
    private let coalesceInterval: TimeInterval
    private var lastDelivery: [String: (state: SessionState, at: Date)] = [:]

    /// Invoked with a session id when the user clicks a notification.
    public var onActivate: ((String) -> Void)?

    public init(
        sink: NotificationSink = UNNotificationSink(),
        now: @escaping () -> Date = Date.init,
        coalesceInterval: TimeInterval = 2.0
    ) {
        self.sink = sink
        self.now = now
        self.coalesceInterval = coalesceInterval
        let unSink = sink as? UNNotificationSink
        self.unSink = unSink
        unSink?.onActivate = { [weak self] id in
            Task { @MainActor in
                self?.onActivate?(id)
            }
        }
    }

    /// Requests `.alert`/`.sound` authorization. A no-op unless wired to the real
    /// `UNNotificationSink` — with a test sink this never touches
    /// `UNUserNotificationCenter`.
    public func requestAuthorization() async {
        await unSink?.requestAuthorization()
    }

    /// Human-readable copy for a session's current state (pure; testable).
    public nonisolated static func message(for session: Session) -> String? {
        switch session.state {
        case .finished: return "\(session.title) · finished"
        case .waitingPermission: return "\(session.title) · needs permission"
        case .waitingIdle: return "\(session.title) · waiting for input"
        case .error: return "\(session.title) · ended with an error"
        default: return nil
        }
    }

    /// Post a notification describing the session's new state. Does nothing if the
    /// state has no associated copy. Dedupes: if the same session id was already posted
    /// in the same state within `coalesceInterval`, this call is skipped; otherwise it's
    /// recorded and handed to the sink.
    public func post(session: Session) {
        guard let body = Self.message(for: session) else { return }
        let timestamp = now()
        if let last = lastDelivery[session.id],
           last.state == session.state,
           timestamp.timeIntervalSince(last.at) < coalesceInterval {
            return
        }
        lastDelivery[session.id] = (state: session.state, at: timestamp)
        sink.deliver(id: session.id, title: "linkC", body: body)
    }
}
