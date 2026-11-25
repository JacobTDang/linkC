import Foundation
import Observation

/// The known-projects list and plan limits the app last built for `projects.json`, in-process, so the
/// app's own views draw from them rather than reading the file back. Observers hear only of a value
/// that changed: the sweep rebuilds both every second, and an equal one must not redraw anything.
///
/// Observed by hand, not through `@Observable`: whether that macro skips an equal value depends on the
/// toolchain (Swift 6.3's does), so `publish`'s guards alone decide, on every toolchain.
@MainActor
public final class KnownProjectsFeed: Observable {
    private let registrar = ObservationRegistrar()
    private var storedProjects: [KnownProject] = []
    private var storedLimits: [String: [KnownLimit]] = [:]

    public var projects: [KnownProject] {
        registrar.access(self, keyPath: \.projects)
        return storedProjects
    }

    /// Each agent's plan limits, keyed by `AgentKind.rawValue`, as `projects.json` lists them.
    public var limits: [String: [KnownLimit]] {
        registrar.access(self, keyPath: \.limits)
        return storedLimits
    }

    public init() {}

    public func publish(_ projects: [KnownProject], limits: [String: [KnownLimit]]) {
        if projects != storedProjects {
            registrar.withMutation(of: self, keyPath: \.projects) { storedProjects = projects }
        }
        if limits != storedLimits {
            registrar.withMutation(of: self, keyPath: \.limits) { storedLimits = limits }
        }
    }
}
