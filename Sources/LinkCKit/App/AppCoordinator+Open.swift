import Foundation

/// A prompt the `linkc` command asked for, waiting for its agent to be ready.
struct OpeningPrompt: Equatable {
    let text: String
    /// When the session was opened: a prompt still waiting `pasteNegotiationTimeout` later is dropped.
    let since: Date
}

extension AppCoordinator {
    /// How old a request may be and still open a session: an older one was left while linkC was not running.
    static let openRequestMaxAge: TimeInterval = 60
    /// How long an answer waits for its command before linkC removes it: the command was killed, or gave up.
    static let openAnswerMaxAge: TimeInterval = 300

    /// Answers every request the `linkc` command left: opens its session, or says why not, then clears old answers.
    func handleOpenRequests() {
        guard let openRequests else { return }
        let pending = openRequests.pending()
        guard !pending.isEmpty else { return }
        for request in pending {
            let result = open(request)
            do {
                try openRequests.answer(request.id, with: result)
            } catch {
                NSLog("[linkC] open request %@: the answer could not be written — %@", request.id, String(describing: error))
            }
        }
        openRequests.removeStaleResults(olderThan: Self.openAnswerMaxAge, now: now())
    }

    /// Opens `request`'s agent in its folder: a worker carrying a task pinned to it when the request
    /// carries one, else the user's own session with its prompt waiting to be typed.
    func open(_ request: OpenRequest) -> OpenResult {
        let age = now().timeIntervalSince(request.createdAt)
        guard age <= Self.openRequestMaxAge else {
            return .refused("the request is \(Int(age)) seconds old (linkC was not running to see it in time); run the command again")
        }
        guard request.agent != .shell else { return .refused("a shell is not an agent") }
        let folder = ProjectPath.canonical(request.folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .refused("the folder \(request.folder) does not exist")
        }
        if request.task != nil, request.prompt == nil {
            return .refused("a task needs a prompt")
        }
        let session: Session
        do {
            session = try newSession(cwd: folder, agent: request.agent, tier: request.tier, select: false,
                                     asWorker: request.task != nil)
        } catch {
            return .refused("\(request.agent.displayName) could not start: \(error)")
        }
        if let origin = request.task, let prompt = request.prompt {
            do {
                _ = try InboxStore(workspaceRoot: folder).createTask(
                    from: origin.fromAgent, to: request.agent, fromSessionId: origin.fromSessionId,
                    targetSessionId: session.id, prompt: prompt, files: [])
            } catch {
                stopSession(session.id)
                return .refused("the task could not be recorded: \(error)")
            }
        } else if let prompt = request.prompt {
            openingPrompts[session.id] = OpeningPrompt(text: prompt, since: now())
        }
        onCommandSessionOpened?(session.id)
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return .opened(sessionId: session.id, message: "Opened \(request.agent.displayName) in a linkC window (\(name)).")
    }

    /// Types each waiting prompt into its session once the agent is ready for it: idle, paste negotiated
    /// and settled, outside the injection gap. The same readiness a task brief waits for. A prompt whose
    /// session ended, or whose agent is not ready within `pasteNegotiationTimeout`, is dropped and logged.
    func typeOpeningPrompts() {
        for (id, prompt) in openingPrompts {
            guard let session = store.session(id: id), session.state != .ended,
                  let terminal = terminals.session(id: id) else {
                openingPrompts[id] = nil
                NSLog("[linkC] the linkc prompt for %@ was not typed: its session ended first", id)
                continue
            }
            let settled = terminal.acceptsPaste
                && (terminal.pasteReadySince.map { now().timeIntervalSince($0) >= deliverySettle } ?? false)
            guard isIdle(session.state), injectionGapElapsed(sessionId: id), settled else {
                if now().timeIntervalSince(prompt.since) > Self.pasteNegotiationTimeout {
                    openingPrompts[id] = nil
                    NSLog("[linkC] the linkc prompt for %@ was not typed: %@ was not ready for it within %.0fs",
                          id, session.agentKind.displayName, Self.pasteNegotiationTimeout)
                }
                continue
            }
            openingPrompts[id] = nil
            if terminals.sendInput(sessionId: id, text: prompt.text) {
                recordInjection(sessionId: id, text: prompt.text, startsWork: true)
                store.updateState(id: id, to: .working)
            } else {
                NSLog("[linkC] the linkc prompt for %@ did not reach its terminal", id)
            }
        }
    }
}
