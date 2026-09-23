import Foundation

/// What a session's tab or sidebar row reads in place of its name: its current action, while it
/// is working or waiting on a permission. Any other state, or no action to show, reads as the name.
public struct ShownActivity: Equatable, Sendable {
    public let text: String
    /// Working, not waiting on a permission: the line shimmers.
    public let isWorking: Bool

    public init?(activity: String?, state: SessionState) {
        let text = activity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.applies(to: state), !text.isEmpty else { return nil }
        self.text = text
        self.isWorking = state == .working
    }

    /// Whether a session in `state` shows an action at all — so callers skip reading one otherwise.
    public static func applies(to state: SessionState) -> Bool {
        state == .working || state == .waitingPermission
    }
}
