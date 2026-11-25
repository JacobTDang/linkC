import Foundation
import Observation

/// linkC's own settings — UserDefaults-backed, distinct from claude's config (which linkC
/// reads but never owns; see `SettingsComposer` for that side). Launch-at-login is
/// deliberately absent: `SMAppService` is the system's source of truth for it, and caching
/// it here would drift the moment the user edits Login Items in System Settings.
@MainActor
@Observable
public final class AppPreferences {
    /// Preset global shortcuts — a curated few rather than a custom recorder. Key codes and
    /// modifier masks are Carbon's (raw values, so this file needs no Carbon import).
    public enum HotKeyPreset: String, CaseIterable, Sendable, Identifiable {
        case none
        case optionSpace
        case controlOptionSpace
        case commandShiftL
        case commandOptionC

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none: return "None"
            case .optionSpace: return "⌥ Space"
            case .controlOptionSpace: return "⌃⌥ Space"
            case .commandShiftL: return "⇧⌘ L"
            case .commandOptionC: return "⌥⌘ C"
            }
        }

        /// Carbon virtual key code (kVK_Space = 49, kVK_ANSI_L = 37, kVK_ANSI_C = 8).
        public var keyCode: UInt32? {
            switch self {
            case .none: return nil
            case .optionSpace, .controlOptionSpace: return 49
            case .commandShiftL: return 37
            case .commandOptionC: return 8
            }
        }

        /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
        public var carbonModifiers: UInt32? {
            switch self {
            case .none: return nil
            case .optionSpace: return 0x800
            case .controlOptionSpace: return 0x1000 | 0x800
            case .commandShiftL: return 0x100 | 0x200
            case .commandOptionC: return 0x100 | 0x800
            }
        }
    }

    private enum Keys {
        static let hotKey = "hotKeyPreset"
        static let usageFooter = "showsUsageFooter"
        static let sharedBrowser = "sharedBrowserEnabled"
        static let linkCApps = "linkCApps"
        static let linkCAppsUnreadable = "linkCApps.unreadable"
        static let discordProjects = "discordWebhookProjects"
        static let discordProjectsUnreadable = "discordWebhookProjects.unreadable"
        static let agentsColumn = "agentsColumn"
        static let agentsColumnUnreadable = "agentsColumn.unreadable"
    }

    public var hotKeyPreset: HotKeyPreset {
        didSet { defaults.set(hotKeyPreset.rawValue, forKey: Keys.hotKey) }
    }

    public var showsUsageFooter: Bool {
        didSet { defaults.set(showsUsageFooter, forKey: Keys.usageFooter) }
    }

    public var sharedBrowserEnabled: Bool {
        didSet { defaults.set(sharedBrowserEnabled, forKey: Keys.sharedBrowser) }
    }

    /// Tier → model per agent. Backed by `models.json`, not UserDefaults: `linkc-mcp` is a
    /// separate process with its own defaults domain and needs to read the same mapping.
    public var agentModels: AgentModelSettings {
        didSet {
            switch modelStore.save(agentModels) {
            case .success:
                modelsSaveRefusal = nil
            case .failure(let refusal):
                modelsSaveRefusal = refusal.description
            }
        }
    }

    /// Why the last `agentModels` write to `models.json` was refused, or nil if the last write
    /// (if any) succeeded. Settings surfaces this so a refused edit doesn't just vanish silently.
    public private(set) var modelsSaveRefusal: String?

    /// Apps registered in Settings > APPS, available in every project. JSON in UserDefaults: only
    /// the app reads them.
    public var linkCApps: [LinkCAppSetting] {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(linkCApps), forKey: Keys.linkCApps)
            } catch {
                NSLog("[linkC] the Settings apps could not be saved — %@", String(describing: error))
            }
        }
    }

    /// The project folders (canonical) that have a Discord webhook of their own. The URLs are secrets
    /// and live only in the Keychain (`DiscordWebhooks`).
    public var discordProjects: [String] {
        didSet { defaults.set(discordProjects, forKey: Keys.discordProjects) }
    }

    /// The agents whose column of agent cards the user flipped from its default, by `AgentKind.rawValue`.
    public private(set) var agentsColumnChoices: [String: Bool] {
        didSet { defaults.set(agentsColumnChoices, forKey: Keys.agentsColumn) }
    }

    /// Whether the linkC agents column shows beside this agent's terminal. On by default for every
    /// agent but Claude Code, whose terminal shows the same cards through the linkc-agents mod: linkC
    /// ships the mod to ~/Library/Application Support/linkC/mods/linkc-agents (#98), and Claude Code
    /// loads it from there through the user's CLAUDE_CODE_PLUGIN_DIRS.
    public func showsAgentsColumn(for agent: AgentKind) -> Bool {
        agentsColumnChoices[agent.rawValue] ?? (agent != .claude)
    }

    /// Flips the column for every session of this agent, and remembers it.
    public func toggleAgentsColumn(for agent: AgentKind) {
        agentsColumnChoices[agent.rawValue] = !showsAgentsColumn(for: agent)
    }

    private let defaults: UserDefaults
    private let modelStore: AgentModelStore

    public init(defaults: UserDefaults = .standard, modelStore: AgentModelStore = .applicationSupport) {
        self.defaults = defaults
        self.modelStore = modelStore
        self.hotKeyPreset = defaults.string(forKey: Keys.hotKey)
            .flatMap(HotKeyPreset.init(rawValue:)) ?? .none
        self.showsUsageFooter = defaults.object(forKey: Keys.usageFooter) as? Bool ?? true
        self.sharedBrowserEnabled = defaults.object(forKey: Keys.sharedBrowser) as? Bool ?? true
        self.agentModels = modelStore.load()
        var apps: [LinkCAppSetting] = []
        if let data = defaults.data(forKey: Keys.linkCApps) {
            do {
                apps = try JSONDecoder().decode([LinkCAppSetting].self, from: data)
            } catch {
                // The user's list is never silently destroyed: keep the raw bytes under a
                // separate key before starting empty, so a future fix (or the user) can recover
                // it — only the log line was here before, and a log line is not a backup.
                defaults.set(data, forKey: Keys.linkCAppsUnreadable)
                NSLog("[linkC] the Settings apps are unreadable, starting with none — %@", String(describing: error))
            }
        }
        let storedProjects = defaults.object(forKey: Keys.discordProjects)
        if let storedProjects, !(storedProjects is [String]) {
            // The list is kept aside under its own key so it can be recovered, and until the projects are set
            // again in Settings their events go to the default webhook.
            defaults.set(storedProjects, forKey: Keys.discordProjectsUnreadable)
            NSLog("[linkC] the Discord project list is unreadable, starting with none")
        }
        self.discordProjects = storedProjects as? [String] ?? []
        let storedColumn = defaults.object(forKey: Keys.agentsColumn)
        if let storedColumn, !(storedColumn is [String: Bool]) {
            // Kept aside under its own key; every agent reads its default until the column is flipped again.
            defaults.set(storedColumn, forKey: Keys.agentsColumnUnreadable)
            NSLog("[linkC] the agents column choices are unreadable, starting from the defaults")
        }
        self.agentsColumnChoices = storedColumn as? [String: Bool] ?? [:]
        self.linkCApps = apps
    }
}
