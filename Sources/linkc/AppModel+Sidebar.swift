import AppKit
import LinkCKit

/// The sidebar's live inputs. Reads only — the writers are `sampleSidebar()` (once a second while
/// the panel is visible or a torn-off window is open, from the coordinator's sweep, and once as the panel
/// opens) and `markOnScreenSeen()` (just before the selection, the open screen, what a window shows, or the
/// panel's visibility changes) — never a view body.
extension AppModel {
    /// The session whose terminal is actually on screen: selected, no screen layered over it,
    /// panel visible. While a split shows, only a selected pane counts: after a pane ends, the
    /// manager's fallback selection sits behind the grid until `repairSplitSelection()` moves off it.
    /// A selection that lives in a torn-off window is not in the panel: the panel shows a note there.
    var onScreenSessionId: String? {
        guard panelVisible, activeScreen == nil, let id = selectedId else { return nil }
        if let splitProject, !(sidebarState.split(for: splitProject)?.members.contains(id) ?? false) { return nil }
        if host(of: id) != nil { return nil }
        return id
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

    /// Once a second while the panel is visible or a torn-off window is open (`syncSweepVisibility()`),
    /// and once as the panel opens: keep a showing split's
    /// selection on its panes, forget ended sessions, drop split members that are gone, mark what is
    /// on screen as seen, keep the project order, expand projects that just turned coral, and publish
    /// the sidebar's non-observable inputs. The sidebar re-renders on the publish only when one of
    /// them changed — a quiet second re-renders nothing.
    func sampleSidebar() {
        let now = Date()
        repairSplitSelection()
        attention.retain(only: Set(sessions.map(\.id)))
        markOnScreenSeen(at: now)
        pruneSplits()
        pruneTornOff()
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

    /// A split holds its project's live terminals: a member that ended or was stopped drops out, so the
    /// cap and the drop positions match the grid shown, and fewer than two left is no split. Safe across
    /// a relaunch: the sessions and shells linkC relaunches at start-up keep their ids and are live by the
    /// time both coordinators exist, so the guard below keeps the first prune from seeing them as gone.
    /// Without a coordinator and shell coordinator (start-up failed) nothing is live, so nothing can be
    /// judged gone: the saved splits are left alone.
    private func pruneSplits() {
        guard coordinator != nil, shells != nil else { return }
        for project in sidebarState.projectsWithSplits {
            guard let split = sidebarState.split(for: project) else { continue }
            let pruned = split.pruned(keeping: splittableIDs(in: project))
            let gone = split.members.filter { !pruned.members.contains($0) }
            if !gone.isEmpty {
                NSLog("[linkC] split for %@ dropped terminals no longer live there: %@", project, gone.joined(separator: ", "))
            }
            if !pruned.isViable {
                sidebarState.clearSplit(for: project)
            } else if pruned != split {
                sidebarState.setSplit(pruned, for: project)
            }
        }
    }

    /// A torn-off window stays open only while what it shows is live: a terminal that ended closes its
    /// window, and so does a split with fewer than two live terminals left. Same guard as `pruneSplits()`:
    /// without both coordinators nothing is live, so nothing can be judged gone. Each window closed is
    /// logged, and the saved state is written only when one did.
    func pruneTornOff() {
        guard coordinator != nil, shells != nil, !tornOff.isEmpty else { return }
        let activeSplits = Set(sidebarState.projectsWithSplits.filter(splitIsActive))
        let result = tornOff.pruned(liveTerminals: liveTerminalIDs, activeSplits: activeSplits)
        guard !result.closed.isEmpty else { return }
        for item in result.closed {
            switch item {
            case .terminal(let id): NSLog("[linkC] window closed: its terminal %@ is no longer live", id)
            case .split(let project): NSLog("[linkC] window closed: the split for %@ has fewer than two live terminals", project)
            }
        }
        sidebarState.setTornOff(result.kept)
        syncSweepVisibility()
    }

    /// Mark the on-screen session seen, and the one in the key torn-off window while linkC is the
    /// active app. Runs with `sampleSidebar()`, and just before the selection, the open screen, what a
    /// window shows (its focused pane, its split, its existence), or the panel's visibility changes, so a
    /// turn that finished while the user watched never reads as unseen afterwards.
    func markOnScreenSeen(at now: Date = Date()) {
        markSeen(onScreenSessionId, at: now)
        if NSApp.isActive { markSeen(keyWindowSessionId, at: now) }
    }

    /// Marks session `id` seen; nil or an id that isn't a session does nothing.
    func markSeen(_ id: String?, at now: Date) {
        guard let id, let session = sessions.first(where: { $0.id == id }) else { return }
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
