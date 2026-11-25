import Foundation

extension AppCoordinator {
    /// What `session`'s agent reports first-hand about it, for its row in `projects.json`.
    func liveDetail(for session: Session) -> SessionLiveDetail {
        switch session.agentKind {
        case .claude:
            return SessionLiveDetail(contextPercent: sessionStatuses.status(for: session.id)?.contextPercent)
        default:
            return SessionLiveDetail()
        }
    }
}
