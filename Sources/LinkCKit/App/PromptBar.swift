import Foundation
import Observation

/// The agent, model and effort the prompt bar would open its task on, and why.
public struct PromptBarPick: Equatable, Sendable {
    public let agent: AgentKind
    public let tier: ModelTier
    /// The model as the agent's own list names it, or its id when the list gives no other name.
    public let model: String
    public let effort: ReasoningEffort?
    /// What the task is and why other agents were passed over, without the agent, model and effort.
    public let reason: String

    public init(agent: AgentKind, tier: ModelTier, model: String, effort: ReasoningEffort?, reason: String) {
        self.agent = agent
        self.tier = tier
        self.model = model
        self.effort = effort
        self.reason = reason
    }

    /// The preview line: "→ Codex · gpt-5.6-sol · medium — implementation".
    public var text: String { "→ \(choice) — \(reason)" }

    /// The agent, model and effort: "Codex · gpt-5.6-sol · medium".
    public var choice: String {
        "\(agent.shortName) · \(model)" + (effort.map { " · \($0.rawValue)" } ?? "")
    }

    /// The same pick, with `note` added to its reason.
    func noting(_ note: String) -> PromptBarPick {
        PromptBarPick(agent: agent, tier: tier, model: model, effort: effort, reason: "\(reason); \(note)")
    }

    /// The same pick, giving `reason` instead.
    func because(_ reason: String) -> PromptBarPick {
        PromptBarPick(agent: agent, tier: tier, model: model, effort: effort, reason: reason)
    }

    /// Whether `other` opens the same session: the same agent, tier, model and effort, whatever the reason.
    func opensLike(_ other: PromptBarPick) -> Bool {
        agent == other.agent && tier == other.tier && model == other.model && effort == other.effort
    }
}

/// What the line under the prompt bar says.
public enum PromptBarLine: Equatable, Sendable {
    /// Nothing typed, or the typing has not paused yet for a first pick.
    case idle
    case pick(PromptBarPick)
    /// Enter found a pick other than the one on the line, as when the previewed agent's own CLI
    /// refused its model: nothing opened, and a second Enter opens this one.
    case confirm(PromptBarPick)
    /// Why the task cannot open: the router's own refusal, or the launch's error.
    case error(String)
    /// Enter was pressed and the session is on its way.
    case opening(String)
    /// The session opened: "Opened Codex — implementation".
    case opened(String)

    /// The whole line, as its tooltip shows it.
    public var text: String {
        switch self {
        case .idle: return ""
        case .pick(let pick): return pick.text
        case .confirm(let pick): return "Enter again to open \(pick.choice) — \(pick.reason)"
        case .error(let message), .opening(let message), .opened(let message): return message
        }
    }
}

/// A session the prompt bar asks for: the user's own, of `agent` in `folder`, on `tier`'s model and
/// `effort`, with `prompt` as its opening prompt.
public struct PromptBarLaunch: Equatable, Sendable {
    public let folder: String
    public let agent: AgentKind
    public let tier: ModelTier
    public let effort: ReasoningEffort?
    public let prompt: String
}

/// The prompt bar: the user types a task once; linkC shows which agent, model and effort the router
/// picks for it, and Enter opens that session in the project on screen with the task as its opening
/// prompt. Tab moves the pick to the next agent that could take the task; Esc clears.
///
/// The preview waits for the typing to pause, reads the routing facts off the main thread, and never
/// runs an agent's CLI. Only Enter asks the picked agent's own CLI about its model, as the MCP tool's
/// auto-route does: both route through `TaskRouting`.
@MainActor
@Observable
public final class PromptBar {
    /// Where the bar reads and what it opens with. `AppCoordinator.promptBarServices` builds the real ones.
    public struct Services {
        /// The project a session opens in: the one on screen, or nil with none.
        let folder: @MainActor () -> String?
        let settings: @MainActor () -> AgentModelSettings
        /// Where routing reads in a folder. Built on the main actor, read off it.
        let inputs: @MainActor (_ folder: String) -> RouteInputs
        /// The app's cached model lists.
        let readLists: @Sendable () throws -> [AgentKind: AgentModelList]
        /// What an agent's own CLI lists in a folder: OpenCode's and Kilo's. Run only on Enter.
        let listFolder: @Sendable (_ agent: AgentKind, _ folder: String) throws -> [String]
        /// Opens the session and returns its id.
        let open: @MainActor (PromptBarLaunch) throws -> String
    }

    public static let noProjectMessage = "Open a project first: the prompt bar opens its session in the project on screen."

    /// What the user typed. Each change waits out the debounce before the pick is read again.
    public var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    public private(set) var line = PromptBarLine.idle
    /// The agent picked by hand with Tab, or nil for the router's own pick.
    public private(set) var override: AgentKind?
    /// Told the id of each session the bar opens.
    public var onOpened: ((String) -> Void)?

    public var isOpening: Bool {
        if case .opening = line { return true }
        return false
    }

    /// The preview being read: after the debounce, or straight away for Tab.
    private(set) var previewWork: Task<Void, Never>?
    /// The agents the typed task could go to, from the last preview.
    private var eligible: [AgentKind] = []
    /// The router's own pick in the last preview.
    private var routerChoice: AgentKind?
    /// Bumped by every change that makes a preview being read out of date.
    private var generation = 0
    /// The pick a first Enter showed in place of the one previewed, for this prompt in this folder: a
    /// second Enter opens it. Any change drops it.
    @ObservationIgnored private var confirming: (pick: PromptBarPick, prompt: String, folder: String)?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let debounce: Duration

    public init(services: Services, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(250)) {
        self.services = services
        self.clock = clock
        self.debounce = debounce
    }

    /// Tab: the pick moves to the next agent that could take the task, and from the last back to the
    /// router's own.
    @discardableResult
    public func cycleAgent() -> Task<Void, Never>? {
        guard !isOpening, !eligible.isEmpty else { return nil }
        let current = override ?? routerChoice
        let next = eligible[((current.flatMap(eligible.firstIndex(of:)) ?? -1) + 1) % eligible.count]
        override = next == routerChoice ? nil : next
        return startPreview(after: nil)
    }

    /// The project on screen changed: the pick is read again there, at once.
    @discardableResult
    public func projectChanged() -> Task<Void, Never>? {
        guard !isOpening, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return startPreview(after: nil)
    }

    /// Esc: empties the bar.
    public func clear() {
        guard !isOpening else { return }
        if text.isEmpty {
            override = nil
            reset()
        } else {
            // Emptying the text resets the rest.
            text = ""
        }
    }

    /// Enter: opens the pick on the line. The picked agent's own CLI is asked about its model first, off
    /// the main thread; a refusal opens nothing and says why. When that leaves another agent to take the
    /// task, or the line showed no pick yet, nothing opens either: the line shows the pick Enter found
    /// and why, and a second Enter opens it.
    @discardableResult
    public func submit() -> Task<Void, Never>? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isOpening else { return nil }
        guard let folder = services.folder() else {
            line = .error(Self.noProjectMessage)
            return nil
        }
        previewWork?.cancel()
        generation += 1
        let shown: PromptBarPick?
        if case .pick(let pick) = line { shown = pick } else { shown = nil }
        let confirmed = confirming.flatMap { $0.prompt == prompt && $0.folder == folder ? $0.pick : nil }
        confirming = nil
        let agent = confirmed?.agent ?? override ?? routerChoice
        line = .opening(agent.map { "Opening \($0.shortName)…" } ?? "Opening…")
        if let confirmed {
            open(confirmed, prompt: prompt, folder: folder)
            return Task {}
        }
        let request = request(prompt: prompt, folder: folder)
        let only = override
        return Task {
            let outcome = await Task.detached { Result { try Self.route(request, only: only) } }.value
            switch outcome {
            case .failure(let error):
                line = .error(Self.message(for: error))
            case .success(let found):
                if let shown, found.pick.opensLike(shown) {
                    open(found.pick, prompt: prompt, folder: folder)
                    return
                }
                // Why the pick moved: the previewed agent's own CLI refused it, when that is what happened.
                let refused = shown.flatMap { shown in
                    found.listingRefusals[shown.agent].map { AgentRefusal(agent: shown.agent, why: $0).message }
                }
                let pick = refused.map { found.pick.because($0) } ?? found.pick
                confirming = (pick, prompt, folder)
                line = .confirm(pick)
            }
        }
    }

    private func open(_ pick: PromptBarPick, prompt: String, folder: String) {
        do {
            let id = try services.open(PromptBarLaunch(
                folder: folder, agent: pick.agent, tier: pick.tier, effort: pick.effort, prompt: prompt))
            override = nil
            // Emptying the text resets the rest.
            text = ""
            line = .opened("Opened \(pick.agent.shortName) — \(pick.reason)")
            onOpened?(id)
        } catch {
            line = .error(Self.message(for: error))
        }
    }

    // MARK: - Preview

    private func textChanged() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            override = nil
            reset()
            return
        }
        startPreview(after: debounce)
    }

    private func reset() {
        previewWork?.cancel()
        previewWork = nil
        generation += 1
        confirming = nil
        eligible = []
        routerChoice = nil
        line = .idle
    }

    /// Reads the pick for the text as it is, after `delay` when given. A newer change cancels it, and
    /// drops a pick waiting for a second Enter.
    @discardableResult
    private func startPreview(after delay: Duration?) -> Task<Void, Never> {
        previewWork?.cancel()
        generation += 1
        confirming = nil
        switch line {
        case .confirm, .opened: line = .idle
        case .idle, .pick, .error, .opening: break
        }
        let generation = generation
        let clock = clock
        let task = Task {
            if let delay {
                // Cancelled by the next keystroke, which starts its own wait.
                do { try await clock.sleep(for: delay) } catch { return }
            }
            await preview(generation: generation)
        }
        previewWork = task
        return task
    }

    private func preview(generation: Int) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let folder = services.folder() else {
            line = .error(Self.noProjectMessage)
            return
        }
        let request = request(prompt: prompt, folder: folder)
        let only = override
        let outcome = await Task.detached { Self.preview(request, only: only) }.value
        guard generation == self.generation else { return }
        switch outcome {
        case .failure(let error):
            eligible = []
            routerChoice = nil
            line = .error(Self.message(for: error))
        case .success(let read):
            eligible = read.eligible
            routerChoice = read.routerChoice
            override = read.override
            switch read.shown {
            case .success(let pick): line = .pick(pick)
            case .failure(let error): line = .error(Self.message(for: error))
            }
        }
    }

    private func request(prompt: String, folder: String) -> RouteRequest {
        RouteRequest(
            prompt: prompt, folder: folder, settings: services.settings(), inputs: services.inputs(folder),
            readLists: services.readLists, listFolder: services.listFolder)
    }

    // MARK: - Routing, off the main thread

    /// Everything one read of the pick needs, gathered on the main actor.
    private struct RouteRequest: Sendable {
        let prompt: String
        let folder: String
        let settings: AgentModelSettings
        let inputs: RouteInputs
        let readLists: @Sendable () throws -> [AgentKind: AgentModelList]
        let listFolder: @Sendable (AgentKind, String) throws -> [String]

        var sources: TierModelSources {
            TierModelSources(readLists: readLists) { [listFolder, folder] in try listFolder($0, folder) }
        }
    }

    /// One preview: the agents the task could go to, the router's own pick, the agent picked by hand
    /// while it can still take the task, and what the line shows — that agent when there is one.
    private struct PreviewRead: Sendable {
        let eligible: [AgentKind]
        let routerChoice: AgentKind?
        let override: AgentKind?
        let shown: Result<PromptBarPick, any Error>
    }

    nonisolated private static func preview(_ request: RouteRequest, only: AgentKind?) -> Result<PreviewRead, any Error> {
        Result {
            let sources = request.sources
            let context = try TaskRouting.gather(
                prompt: request.prompt, settings: request.settings, sources: sources, inputs: request.inputs)
            let eligible = context.eligible(settings: request.settings)
            let routed = Result {
                try pick(request, context: context, sources: sources, only: nil, consultingFolderListing: false)
            }
            let routerChoice: AgentKind?
            if case .success(let pick) = routed { routerChoice = pick.agent } else { routerChoice = nil }
            guard let only else {
                return PreviewRead(eligible: eligible, routerChoice: routerChoice, override: nil, shown: routed)
            }
            // The agent picked by hand can no longer take the task: the router's pick shows, saying why.
            if let why = TaskRouting.handPickRefusal(only, context: context, settings: request.settings) {
                let dropped = AgentRefusal(agent: only, why: why).message
                return PreviewRead(
                    eligible: eligible, routerChoice: routerChoice, override: nil,
                    shown: routed.map { $0.noting(dropped) })
            }
            let shown = Result {
                try pick(request, context: context, sources: sources, only: only, consultingFolderListing: false)
            }
            return PreviewRead(eligible: eligible, routerChoice: routerChoice, override: only, shown: shown)
        }
    }

    /// What Enter found: the pick, after asking its agent's own CLI, and the agents that CLI check refused.
    private struct EnterRead: Sendable {
        let pick: PromptBarPick
        let listingRefusals: [AgentKind: String]
    }

    nonisolated private static func route(_ request: RouteRequest, only: AgentKind?) throws -> EnterRead {
        let sources = request.sources
        let context = try TaskRouting.gather(
            prompt: request.prompt, settings: request.settings, sources: sources, inputs: request.inputs)
        let routed = try TaskRouting.pick(
            prompt: request.prompt, context: context, settings: request.settings, sources: sources,
            only: only, consultingFolderListing: true)
        return EnterRead(
            pick: try pick(request, decision: routed.decision, sources: sources), listingRefusals: routed.listingRefusals)
    }

    nonisolated private static func pick(
        _ request: RouteRequest, context: RouteContext, sources: TierModelSources, only: AgentKind?,
        consultingFolderListing: Bool
    ) throws -> PromptBarPick {
        let decision = try TaskRouting.pick(
            prompt: request.prompt, context: context, settings: request.settings, sources: sources,
            only: only, consultingFolderListing: consultingFolderListing).decision
        return try pick(request, decision: decision, sources: sources)
    }

    nonisolated private static func pick(
        _ request: RouteRequest, decision: RouterDecision, sources: TierModelSources
    ) throws -> PromptBarPick {
        guard let configured = request.settings.model(for: decision.agent, tier: decision.tier) else {
            throw LinkCError.process(
                "no model configured for \(decision.agent.rawValue) tier \(decision.tier.rawValue) — set it in linkC's Settings > Models")
        }
        // The model the session launches with, as `AppCoordinator.resolvedModel` resolves it.
        let id = decision.agent == .opencode
            ? OpenCodeGo.model(for: configured, listed: try sources.modelLists()[.opencode]?.models ?? [])
            : configured
        let reason = ([decision.summary] + decision.notes).joined(separator: "; ")
        return PromptBarPick(
            agent: decision.agent, tier: decision.tier, model: try modelName(id, agent: decision.agent, sources: sources),
            effort: decision.effort, reason: reason)
    }

    /// `id` as `agent`'s list names it. Claude's and Codex's lists are fixed; a listed agent with no list
    /// read yet is named by the id. An unreadable list throws, though routing has already refused every
    /// listed agent then.
    nonisolated private static func modelName(_ id: String, agent: AgentKind, sources: TierModelSources) throws -> String {
        let listed = try ModelListParser.fixed(for: agent)
            ?? ModelListCache.liveModels(for: agent, lists: sources.modelLists())
            ?? []
        return listed.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name ?? id
    }

    /// The router's refusal without the MCP tool's `to` remedy, which only that tool's caller can follow.
    nonisolated private static func message(for error: any Error) -> String {
        (error as? RouterRefusal)?.message ?? error.localizedDescription
    }
}
