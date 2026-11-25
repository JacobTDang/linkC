import Foundation

extension AppCoordinator {
    /// Hands off a live session's context to a new session of `agent`: opens the user's own session of
    /// `agent` in the same folder, on the tier's model or the model given, then writes the memo from the
    /// source session (its agent, last 50 lines on screen, git summary and goal) to
    /// `.linkc/handoffs/<new session id>.md` and queues an opening prompt telling it to read the memo
    /// and continue.
    ///
    /// Leaves the source session running.
    @discardableResult
    public func handoff(
        from sessionId: String,
        to agent: AgentKind,
        tier: ModelTier? = nil,
        model: String? = nil,
        goal: String? = nil,
        select: Bool = true
    ) throws -> Session {
        guard let sourceSession = store.session(id: sessionId) else {
            throw LinkCError.process("no linkC session \(sessionId) to hand off")
        }
        guard sourceSession.state != .ended else {
            throw LinkCError.process("\(sourceSession.agentKind.displayName)'s session \(sessionId) has ended; there is nothing live to hand off")
        }
        guard agent != .shell else {
            throw LinkCError.process("a shell is not an agent")
        }
        if tier != nil, model != nil {
            throw LinkCError.process("pass tier or model, not both")
        }
        if agent == .freebuff, (tier != nil || model != nil) {
            throw LinkCError.process("Freebuff has no tiers; it runs its own default model.")
        }
        if agent == .cursor, (tier != nil || model != nil) {
            throw LinkCError.process("cursor cannot be pinned to a model")
        }

        let folder = ProjectPath.canonical(sourceSession.cwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinkCError.process("the folder \(folder) does not exist")
        }

        let resolvedModelId: String?
        if let model {
            let lists: [AgentKind: AgentModelList]
            do {
                lists = try modelLists()
            } catch {
                throw LinkCError.process("could not read the live model lists — \(error)")
            }
            let choosable = ModelListCache.choosable(for: agent, lists: lists, settings: liveModelSettings())
            if agent == .opencode, !OpenCodeFreeModels.isFree(model) {
                let free = choosable.filter { OpenCodeFreeModels.isFree($0.id) }.map { $0.id }.joined(separator: ", ")
                throw LinkCError.process("\(model) is not free — OpenCode runs free models only. Free models: \(free)")
            }
            if agent == .kilo, !KiloFreeModels.isFree(model) {
                let free = choosable.filter { KiloFreeModels.isFree($0.id) }.map { $0.id }.joined(separator: ", ")
                throw LinkCError.process("\(model) is not free — Kilo runs free models only. Free models: \(free)")
            }
            if agent == .crush, !CrushFreeModels.isFree(model) {
                let free = choosable.filter { CrushFreeModels.isFree($0.id) }.map { $0.id }.joined(separator: ", ")
                throw LinkCError.process("\(model) is not free — Crush runs free models only. Free models: \(free)")
            }
            guard let listed = choosable.first(where: { $0.id.caseInsensitiveCompare(model) == .orderedSame }) else {
                let ids = choosable.map { $0.id }.joined(separator: ", ")
                throw LinkCError.process("\(model) is not among the models \(agent.displayName) lists. Available: \(ids)")
            }
            resolvedModelId = listed.id
        } else if let tier {
            // The tier only picks the model. The new session is the user's own and runs unpinned, as one
            // opened from the panel does: pinned to the tier, the relay would hand it delegated tasks.
            guard let tierModel = resolvedModel(for: agent, tier: tier) else {
                throw LinkCError.process("no model configured for \(agent.rawValue) tier \(tier.rawValue) — set it in linkC's Settings > Models")
            }
            resolvedModelId = tierModel
        } else {
            resolvedModelId = nil
        }

        let recentOutput: String?
        if let terminal = terminals.session(id: sourceSession.id) {
            let out = terminal.recentOutput(lines: 50)
            recentOutput = out.isEmpty ? nil : out
        } else {
            recentOutput = nil
        }

        let gitSummary = gitStatusSummary(in: folder)

        let resolvedGoal = try handoffGoal(of: sourceSession, in: folder, explicit: goal)

        let memo = HandoffComposer.compose(
            workspacePath: folder,
            sourceAgent: sourceSession.agentKind,
            lastGoal: resolvedGoal,
            gitSummary: gitSummary,
            recentTerminalOutput: recentOutput
        )

        let newSession: Session
        do {
            newSession = try self.newSession(cwd: folder, agent: agent, mode: .new, model: resolvedModelId,
                                             select: select, asWorker: false)
        } catch {
            throw LinkCError.process("\(agent.displayName) could not start: \(error)")
        }
        // Written once the session is up and has an id to name the memo for, so a launch that fails
        // leaves nothing behind.
        let memoPath = HandoffComposer.sessionMemoPath(for: newSession.id)
        do {
            try HandoffComposer.writeHandoff(workspacePath: folder, content: memo, at: memoPath)
        } catch {
            terminals.terminate(newSession.id)
            cleanup(sessionId: newSession.id, end: .abandoned)
            throw LinkCError.process("the handoff memo \(memoPath) could not be written, so the new session was closed — \(error)")
        }

        let promptText: String
        if let resolvedGoal, !resolvedGoal.isEmpty {
            promptText = "Please read \(memoPath) and continue working on: \(resolvedGoal)"
        } else {
            promptText = "Please read \(memoPath) and continue."
        }
        openingPrompts[newSession.id] = OpeningPrompt(text: promptText, since: now())

        return newSession
    }

    /// The goal a handoff from `session` continues: the one given, else the newest task the session
    /// carries. Never another session's task or the board's goal, which are other agents' work, and
    /// never the session's title, which is its folder's name.
    private func handoffGoal(of session: Session, in folder: String, explicit: String?) throws -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let carried: [TaskRecord]
        do {
            carried = try InboxStore(workspaceRoot: folder).openTasks()
                .filter { $0.assigneeSessionId == session.id && ($0.state == .delivered || $0.state == .started) }
        } catch {
            throw LinkCError.process("could not read the tasks \(session.agentKind.displayName) carries — \(error)")
        }
        return carried.last?.prompt
    }

    /// Deletes the memo a handoff wrote for `session`, now that the session it was for has ended:
    /// it holds a stretch of terminal output the project has no use for after that. The path comes
    /// from the session's folder and id, so a memo written before linkC restarted goes too. No memo
    /// is fine; one that cannot be deleted is said.
    func removeHandoffMemo(of session: Session) {
        let memo = URL(fileURLWithPath: session.cwd).appendingPathComponent(HandoffComposer.sessionMemoPath(for: session.id))
        do {
            try FileManager.default.removeItem(at: memo)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            NSLog("[linkC] could not delete the handoff memo %@ — %@", memo.path, String(describing: error))
            notifications.postLocal(title: "linkC: could not delete a handoff memo", body: "\(memo.path) — \(error)")
        }
    }
}
