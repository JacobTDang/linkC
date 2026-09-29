import Foundation
import LinkCKit

/// The sidebar's live inputs. Reads only — the writers are `sampleSidebar()` (once a second,
/// from the shell sweep, and as the panel shows) and `markOnScreenSeen()` (just before the
/// selection, the open screen, or the panel's visibility changes) — never a view body.
extension AppModel {
    /// The session whose terminal is actually on screen: selected, no screen layered over it,
    /// panel visible.
    var onScreenSessionId: String? {
        guard panelVisible, activeScreen == nil else { return nil }
        return selectedId
    }

    /// Every live session's row title, keyed by session id.
    var sessionTitles: [String: String] {
        SessionTitles.resolve(
            sessions: sessions,
            claudeTitle: { usage.sessionTitle($0) },
            heldTask: { heldTask(for: $0) }
        )
    }

    /// The task a session is holding, read from its project's inbox file — which no observation
    /// sees change, so `sampleSidebar()` watches it for the sidebar.
    private func heldTask(for session: Session) -> TaskRecord? {
        inbox(for: session.cwd).flatMap { SessionTitles.heldTask(for: session, in: $0.tasks) }
    }

    func rowStatus(_ session: Session, now: Date = Date()) -> SessionRowStatus {
        attention.status(
            for: session,
            onScreen: session.id == onScreenSessionId,
            rateLimited: session.state == .error && agentLimit(for: session) != nil,
            now: now
        )
    }

    /// The session's current action ("$ swift test", "Thinking…", etc.) while it's working,
    /// and while it's blocked on a permission prompt. Idle sessions never state an absence.
    func currentActivity(_ session: Session) -> String? {
        if let hookActivity = usage.sessionActivity(session.id), !hookActivity.isEmpty {
            return hookActivity
        }
        if let term = coordinator?.terminals.session(id: session.id),
           let liveActivity = term.liveActivityLine(), !liveActivity.isEmpty {
            return liveActivity
        }
        if session.agentKind == .claude, session.state.bucket == .active {
            return "Thinking…"
        }
        if session.state == .waitingPermission {
            return "Permission required"
        }
        return nil
    }

    /// What a session's sidebar row says in place of its name, or nil. An action a state does not
    /// show is never read.
    private func shownActivity(_ session: Session) -> ShownActivity? {
        guard ShownActivity.applies(to: session.state) else { return nil }
        return ShownActivity(activity: currentActivity(session), state: session.state)
    }

    /// A session's action line as its row shows it, read from the terminal now. nil is
    /// authoritative: the session is gone, or there is no line to show. Reads no more than the
    /// one session — a row's own timeline calls this, not the whole sidebar.
    func liveActivity(id: String) -> String? {
        coordinator?.store.session(id: id).flatMap { shownActivity($0)?.text }
    }

    /// The sidebar's Projects rows and the terminals that belong to none of them — built once from
    /// the same inputs, so a caller needing both never builds the model twice. Called from the
    /// sidebar's body: the observable state it reads re-renders the sidebar the moment it changes,
    /// and `sidebarSignal` covers the inputs that are not observable.
    func sidebarSections(now: Date = Date()) -> (projects: [SidebarProject], unfiled: [ShellRow]) {
        let titles = sessionTitles
        let inputs = sessions.map { session in
            SidebarModel.Input(
                session: session,
                title: titles[session.id] ?? session.agentKind.shortName,
                status: rowStatus(session, now: now),
                hasRunningSubagents: usage.sessionAgents(session.id).contains(where: \.isRunning),
                activity: shownActivity(session)?.text
            )
        }
        return SidebarModel.projects(
            inputs: inputs,
            shells: shellRows,
            filed: sidebarState.terminalProjects,
            order: sidebarState.projectOrder,
            expandOverrides: sidebarState.expandOverrides,
            selectedId: selectedId
        )
    }

    /// Every known project's folder, standardized: live sessions', plus any project that holds a
    /// live filed terminal — exactly the paths `sidebarSections` would show as project rows.
    /// Lets a terminal's project be resolved (`TerminalFiling.project`) without building the model.
    var knownProjectPaths: Set<String> {
        Set(sessions.map(\.cwd))
            .union(shellRows.compactMap { sidebarState.terminalProjects[$0.id] })
    }

    /// Sessions that want the user — drives the menu-bar tint.
    var attentionCount: Int {
        sessions.count { rowStatus($0).isCoral }
    }

    /// Running compose projects plus standalone containers, or nil when the Servers section hides.
    var serverSummary: Int? {
        let running = runningProjectsByPower.count + runningStandaloneByPower.count
        return (running > 0 || dockerVmCpu != nil) ? running : nil
    }

    /// Oracle, Supabase, and watched rows, or nil when the Cloud section hides.
    var cloudSummary: Int? {
        let rows = cloudInstances.count + supabaseProjects.count + configuredEndpoints.count
        return (rows > 0 || supabaseNeedsLogin || !cloudErrors.isEmpty) ? rows : nil
    }

    /// Once a second, and as the panel shows: forget ended sessions, mark what is on screen as
    /// seen, keep the project order, expand projects that just turned coral, and publish the
    /// sidebar's non-observable inputs. The sidebar re-renders on the publish only when one of
    /// them changed — a quiet second re-renders nothing.
    func sampleSidebar() {
        let now = Date()
        attention.retain(only: Set(sessions.map(\.id)))
        markOnScreenSeen(at: now)
        // Filed paths are canonical already: `SidebarState` canonicalizes them as it files them.
        let filedPaths = Set(sidebarState.terminalProjects.values).sorted()
        sidebarState.noteProjects(ProjectGroup.group(sessions: sessions).map(\.workspacePath) + filedPaths)
        let selectedProject: String?
        if let session = sessions.first(where: { $0.id == selectedId }) {
            selectedProject = session.cwd
        } else if let shell = shellRows.first(where: { $0.id == selectedId }) {
            selectedProject = TerminalFiling.project(
                forTerminal: shell.id, cwd: shell.cwd, filed: sidebarState.terminalProjects, projects: knownProjectPaths)
        } else {
            selectedProject = nil
        }
        sidebarState.noteSelectedProject(selectedProject)
        sidebarSignal.publish(SidebarSignal(
            sessions: sessions,
            heldTitle: { heldTask(for: $0).map(SessionTitles.taskTitle) },
            isRateLimited: { agentLimit(for: $0) != nil },
            action: { currentActivity($0) }))
        // A project is coral while any of its sessions is: the same test its row's dot uses.
        sidebarState.noteCoral(Set(sessions.filter { rowStatus($0, now: now).isCoral }.map(\.cwd)))
    }

    /// Mark the on-screen session seen. Runs once a second from the sweep, and just before the
    /// selection, the open screen, or the panel's visibility changes, so a turn that finished
    /// while the user watched never reads as unseen afterwards.
    func markOnScreenSeen(at now: Date = Date()) {
        guard let id = onScreenSessionId, let session = sessions.first(where: { $0.id == id }) else { return }
        attention.markSeen(session, at: now)
    }

    /// Checks if a session's agent has an active rate limit recorded in the inbox.
    func agentLimit(for session: Session) -> AgentLimitStatus? {
        let norm = session.cwd
        guard let inbox = inbox(for: norm) else { return nil }
        let now = Date()
        if let limit = inbox.agentLimits.first(where: { $0.agent == session.agentKind }),
           limit.cooldownExpiresAt > now {
            return limit
        }
        return nil
    }

    /// Every agent's most recent live cap across the workspaces that have a session. When an agent
    /// is capped in more than one, the furthest-out cooldown wins: that is when it can work again.
    var agentLimits: [AgentKind: AgentLimitStatus] {
        AgentLimitsCache.limits(for: Set(sessions.map(\.cwd))) { [weak self] path in
            self?.inbox(for: path)
        }
    }

    /// The sidebar's Usage section: a row per agent that reports something, the rest listed with
    /// the reason they do not.
    func usageRows(now: Date = Date()) -> UsageRows.Result {
        UsageRows.build(claude: coordinator?.claudeUsage, codex: codexUsage, limits: agentLimits, now: now)
    }
}

/// In-memory cache for workspace agent limits to prevent repetitive synchronous disk reads
/// on the main actor when `TimelineView` evaluates `usageRows` every 30s.
@MainActor
enum AgentLimitsCache {
    private static var cached: [AgentKind: AgentLimitStatus] = [:]
    private static var lastFetched: Date = .distantPast
    private static var lastPaths: Set<String> = []
    private static let ttl: TimeInterval = 60.0

    static func limits(
        for paths: Set<String>,
        now: Date = Date(),
        fetchInbox: (String) -> Inbox?
    ) -> [AgentKind: AgentLimitStatus] {
        if paths == lastPaths, now.timeIntervalSince(lastFetched) < ttl {
            return cached
        }
        var latest: [AgentKind: AgentLimitStatus] = [:]
        for path in paths {
            for limit in fetchInbox(path)?.agentLimits ?? [] {
                if let existing = latest[limit.agent], existing.cooldownExpiresAt >= limit.cooldownExpiresAt {
                    continue
                }
                latest[limit.agent] = limit
            }
        }
        cached = latest
        lastFetched = now
        lastPaths = paths
        return latest
    }
}
