import Foundation

/// Whether the menu-bar panel is on screen: its window ordered in on the active Space, with no hide
/// fading it out. The window decides, not the code that shows and hides it: a panel leaves the screen
/// in ways that never pass through `hide()` (another Space, the app hidden), and SwiftUI's `onAppear`
/// fires for a window that was never shown.
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

    /// linkC is about to show the panel. It counts as present before the window orders in, and wins
    /// over a hide still fading out.
    public func willPresent() {
        hideInFlight = false
        updatePresence(to: true)
    }

    /// linkC is hiding the panel. It stops counting as present at once, though the window stays
    /// ordered in while it fades.
    public func willHide() {
        hideInFlight = true
        updatePresence(to: false)
    }

    /// The hide's window is ordered out.
    public func didFinishHide() {
        hideInFlight = false
        reconcile()
    }

    /// The window was ordered in or out, or the active Space changed.
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
