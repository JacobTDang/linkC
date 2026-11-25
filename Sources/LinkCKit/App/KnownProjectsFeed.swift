import Foundation
import Observation

/// The known-projects list the app last built for `projects.json`, in-process, so the app's own views
/// draw from the list rather than reading the file back. Observers hear only of a list that changed:
/// the sweep rebuilds it every second, and an equal one must not redraw anything.
///
/// Observed by hand, not through `@Observable`: whether that macro skips an equal value depends on the
/// toolchain (Swift 6.3's does), so `publish`'s guard alone decides, on every toolchain.
@MainActor
public final class KnownProjectsFeed: Observable {
    private let registrar = ObservationRegistrar()
    private var stored: [KnownProject] = []

    public var projects: [KnownProject] {
        registrar.access(self, keyPath: \.projects)
        return stored
    }

    public init() {}

    public func publish(_ new: [KnownProject]) {
        guard new != stored else { return }
        registrar.withMutation(of: self, keyPath: \.projects) { stored = new }
    }
}
