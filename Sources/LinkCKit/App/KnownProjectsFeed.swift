import Foundation
import Observation

/// The known-projects list the app last built for `projects.json`, in-process, so the app's own views
/// draw from the list rather than reading the file back. Observers hear only of a list that changed:
/// the sweep rebuilds it every second, and an equal one must not redraw anything.
@MainActor
@Observable
public final class KnownProjectsFeed {
    public private(set) var projects: [KnownProject] = []

    public init() {}

    /// Whether Observation itself skips an equal assignment depends on the toolchain's library, so the
    /// guard is explicit.
    public func publish(_ new: [KnownProject]) {
        guard new != projects else { return }
        projects = new
    }
}
