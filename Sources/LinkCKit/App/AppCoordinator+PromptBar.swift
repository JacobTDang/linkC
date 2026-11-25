import Foundation

extension AppCoordinator {
    /// What the prompt bar reads and opens with. Routing reads what the MCP tool's auto-route reads,
    /// from linkC's own state: the agents linkC can launch, the folder's inbox limits, the same usage
    /// readers, and the sessions open in the folder. `readLists` defaults to the cache the coordinator
    /// reads; `listFolder` to the OpenCode and Kilo listings the MCP tool runs.
    public func promptBarServices(
        folder: @escaping @MainActor () -> String?,
        readLists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = {
            try ModelListCache.applicationSupport.read()
        },
        listFolder: @escaping @Sendable (AgentKind, String) throws -> [String] = { agent, folder in
            agent == .kilo
                ? try MCPServer.listKiloModels(in: folder, timeout: AppCoordinator.openCodeModelListingTimeout)
                : try MCPServer.listOpenCodeModels(in: folder, timeout: AppCoordinator.openCodeModelListingTimeout)
        }
    ) -> PromptBar.Services {
        PromptBar.Services(
            folder: folder,
            settings: { self.liveModelSettings() },
            inputs: { self.promptBarRouteInputs(folder: $0) },
            readLists: readLists,
            listFolder: listFolder,
            open: { try self.openRouted($0).id })
    }

    /// Where the prompt bar's routing reads in `folder`. The open sessions are read now, on the main actor;
    /// the rest when routing asks, off it.
    func promptBarRouteInputs(folder: String) -> RouteInputs {
        let norm = ProjectPath.canonical(folder)
        let open = Set(store.sessions.filter { $0.cwd == norm && $0.state != .ended }.map(\.agentKind))
        let claudePath = claudePath
        let resolver = agentPathResolver
        let inbox = InboxStore(workspaceRoot: norm)
        return RouteInputs(
            // Installed means launchable, as `launch` finds the executable: Claude at its path, the others
            // through the injected resolver when there is one, else on disk.
            isInstalled: { agent in
                if agent == .claude { return FileManager.default.isExecutableFile(atPath: claudePath) }
                if let resolver { return resolver(agent) != nil }
                return AgentDescriptor.resolveExecutable(for: agent) != nil
            },
            liveLimits: { try inbox.liveLimits(agent: $0) },
            usageReaders: usageReaders,
            agentsOpen: { (open, nil) })
    }

    /// Opens the prompt bar's pick: the user's own session of `launch.agent` in its folder, with the task
    /// waiting as its opening prompt. The tier only picks the model: the session runs unpinned, as a
    /// handoff's does, so the relay never hands it a delegated task.
    @discardableResult
    func openRouted(_ launch: PromptBarLaunch) throws -> Session {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinkCError.process("the folder \(launch.folder) does not exist")
        }
        guard let model = resolvedModel(for: launch.agent, tier: launch.tier) else {
            throw LinkCError.process(
                "no model configured for \(launch.agent.rawValue) tier \(launch.tier.rawValue) — set it in linkC's Settings > Models")
        }
        let session: Session
        do {
            session = try newSession(cwd: launch.folder, agent: launch.agent, mode: .new, model: model,
                                     effort: launch.effort, select: true, asWorker: false)
        } catch {
            throw LinkCError.process("\(launch.agent.displayName) could not start: \(error)")
        }
        openingPrompts[session.id] = OpeningPrompt(text: launch.prompt, since: now())
        return session
    }
}
