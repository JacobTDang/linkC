import Foundation

/// What linkC does differently for OpenCode. See docs/superpowers/specs/2026-11-07-opencode-agent-design.md.
extension AppCoordinator {
    /// What an OpenCode terminal adds to `LINKC_SESSION`: no update dialog, and an inline config
    /// with the session's model — OpenCode's TUI takes no model flag — and linkC's tool server, so
    /// the tools are there even when registering in `opencode.json` failed. The server entry carries
    /// no session id: OpenCode hands its own environment, `LINKC_SESSION` included, to the servers
    /// it starts. A value already in linkC's environment is merged into, not replaced.
    func openCodeEnvironment(model: String?) throws -> [String: String] {
        var env = AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser)
        env[AgentDescriptor.openCodeConfigContentKey] = try MCPRegistrar.openCodeConfigContent(
            inherited: ProcessInfo.processInfo.environment[AgentDescriptor.openCodeConfigContentKey],
            binaryPath: MCPRegistrar.defaultBinaryPath(),
            model: model)
        return env
    }

    /// The OpenCode conversation a launch opens.
    struct OpenCodeConversationChoice: Equatable {
        /// The id passed to `--session`.
        let id: String
        /// The model the reopened conversation last ran on, which is the default tier's; nil when the
        /// conversation is new.
        let model: String?
        /// Why the user gets a new conversation instead of an earlier one; nil when they do not.
        let notice: String?
    }

    /// The conversation an OpenCode launch opens. A new session gets a new conversation, named by
    /// linkC. A continue or a restore reopens `conversationId`, or without one the folder's newest
    /// conversation that no session or card holds, but only when that conversation last ran on the
    /// default tier's model: OpenCode reopens a conversation on its own model, ahead of linkC's pin.
    /// Throws when OpenCode cannot say which conversations the folder has or which model one ran on,
    /// or when the default tier has no model.
    func openCodeConversation(mode: LaunchMode, conversationId: String?, cwd: String) throws -> OpenCodeConversationChoice {
        guard mode != .new else {
            return OpenCodeConversationChoice(id: OpenCodeConversations.newId(), model: nil, notice: nil)
        }
        let candidate: String
        if let conversationId, !conversationId.isEmpty {
            candidate = conversationId
        } else {
            let held = Set(store.sessions.filter { $0.agentKind == .opencode }.compactMap(\.claudeSessionId))
                .union(manifest.entries.filter { $0.agentKind == .opencode }.compactMap(\.claudeSessionId))
            guard let newest = try openCodeConversations.conversations(cwd).first(where: { !held.contains($0) }) else {
                return OpenCodeConversationChoice(id: OpenCodeConversations.newId(), model: nil,
                                                  notice: "OpenCode has no earlier conversation here, so it started a new one.")
            }
            candidate = newest
        }
        // A conversation OpenCode has not saved never got a message: `--session` creates it under this id.
        guard let model = try openCodeConversations.model(candidate, cwd) else {
            return OpenCodeConversationChoice(id: candidate, model: nil, notice: nil)
        }
        let tier = defaultTier(for: .opencode)
        guard let defaultModel = resolvedModel(for: .opencode, tier: tier) else {
            throw LinkCError.process("no model configured for opencode tier \(tier.rawValue) — set it in linkC settings")
        }
        guard model == defaultModel else {
            return OpenCodeConversationChoice(
                id: OpenCodeConversations.newId(), model: nil,
                notice: "its last conversation ran on \(model), not the default \(defaultModel), so OpenCode started a new one.")
        }
        return OpenCodeConversationChoice(id: candidate, model: model, notice: nil)
    }

    /// Says why an OpenCode session that was meant to continue got a new conversation, in the log
    /// and to the user.
    func tellOpenCodeStartedFresh(title: String, folder: String, reason: String) {
        NSLog("[linkC] %@ (%@): %@", title, folder, reason)
        notifications.postLocal(title: "linkC: OpenCode started a new conversation", body: "\(title): \(reason)")
    }
}
