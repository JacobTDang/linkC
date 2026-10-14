import Foundation

/// Coordinates whether the status panel counts as on screen.
///
/// A panel leaves the screen in ways that never pass through `hide()` (another Space,
/// the app hidden), and SwiftUI's `onAppear` fires for a window that was never shown.
@MainActor
public final class PanelPresence {
    private let isOrderedIn: () -> Bool
    private let isOnActiveSpace: () -> Bool
    private let publish: (Bool) -> Void

    private var hideInFlight = false

    /// The last value published.
    public private(set) var isPresent = false

    public init(
        isOrderedIn: @escaping () -> Bool,
        isOnActiveSpace: @escaping () -> Bool,
        publish: @escaping (Bool) -> Void
    ) {
        self.isOrderedIn = isOrderedIn
        self.isOnActiveSpace = isOnActiveSpace
        self.publish = publish
    }

    /// Clears the hide-in-flight flag and sets present to true.
    /// This happens before the window orders in.
    public func willPresent() {
        hideInFlight = false
        updatePresence(to: true)
    }

    /// Sets hide-in-flight and sets present to false.
    public func willHide() {
        hideInFlight = true
        updatePresence(to: false)
    }

    /// Clears hide-in-flight, then reconciles.
    public func didFinishHide() {
        hideInFlight = false
        reconcile()
    }

    /// Reconciles to `isOrderedIn() && isOnActiveSpace() && !hideInFlight`.
    public func windowStateChanged() {
        reconcile()
    }

    private func reconcile() {
        let shouldBePresent = isOrderedIn() && isOnActiveSpace() && !hideInFlight
        updatePresence(to: shouldBePresent)
    }

    private func updatePresence(to newValue: Bool) {
        guard isPresent != newValue else { return }
        isPresent = newValue
        publish(newValue)
    }
}
