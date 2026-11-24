import Foundation

extension AppCoordinator {
    /// Hands off a live session's context to a new session of `agent`.
    /// Composes and atomically writes `.linkc/HANDOFF.md` from the source session
    /// (its cwd, agentKind, screen tail 50 lines, git summary, resolved goal, title),
    /// then opens a new user-owned session of `agent` in the same cwd on that tier/model
    /// with an opening prompt telling it to read `.linkc/HANDOFF.md` and continue.
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
            throw LinkCError.process("Session '\(sessionId)' not found")
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
            guard resolvedModel(for: agent, tier: tier) != nil else {
                throw LinkCError.process("no model configured for \(agent.rawValue) tier \(tier.rawValue) — set it in linkC's Settings > Models")
            }
            resolvedModelId = nil
        } else {
            resolvedModelId = nil
        }

        // Terminal output tail 50 lines
        let recentOutput: String?
        if let terminal = terminals.session(id: sourceSession.id) {
            let out = terminal.recentOutput(lines: 50)
            recentOutput = out.isEmpty ? nil : out
        } else {
            recentOutput = nil
        }

        // Git summary
        let gitSummary = gitStatusSummary(in: folder)

        // Resolved goal: explicit ?? open tasks / blackboard ?? source session title (if not empty)
        let resolvedGoal = resolveHandoffGoal(workspacePath: folder, explicit: goal)
            ?? (!sourceSession.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sourceSession.title : nil)

        // Compose and write HANDOFF.md
        try HandoffComposer.writeHandoffSync(
            workspacePath: folder,
            sourceAgent: sourceSession.agentKind,
            lastGoal: resolvedGoal,
            gitSummary: gitSummary,
            recentTerminalOutput: recentOutput
        )

        // Launch new user-owned session (asWorker: false)
        let newSession = try newSession(
            cwd: folder,
            agent: agent,
            mode: .new,
            tier: tier,
            model: resolvedModelId,
            select: select,
            asWorker: false
        )

        // Opening prompt
        let promptText: String
        if let resolvedGoal, !resolvedGoal.isEmpty {
            promptText = "Please read .linkc/HANDOFF.md and continue working on: \(resolvedGoal)"
        } else {
            promptText = "Please read .linkc/HANDOFF.md and continue."
        }
        openingPrompts[newSession.id] = OpeningPrompt(text: promptText, since: now())

        return newSession
    }
}
