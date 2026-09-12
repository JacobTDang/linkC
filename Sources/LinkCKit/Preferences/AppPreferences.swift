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
    }

    public var hotKeyPreset: HotKeyPreset {
        didSet { defaults.set(hotKeyPreset.rawValue, forKey: Keys.hotKey) }
    }

    public var showsUsageFooter: Bool {
        didSet { defaults.set(showsUsageFooter, forKey: Keys.usageFooter) }
    }

    /// Tier → model per agent. Backed by `models.json`, not UserDefaults: `linkc-mcp` is a
    /// separate process with its own defaults domain and needs to read the same mapping.
    public var agentModels: AgentModelSettings {
        didSet { modelStore.save(agentModels) }
    }

    private let defaults: UserDefaults
    private let modelStore: AgentModelStore

    public init(defaults: UserDefaults = .standard, modelStore: AgentModelStore = .applicationSupport) {
        self.defaults = defaults
        self.modelStore = modelStore
        self.hotKeyPreset = defaults.string(forKey: Keys.hotKey)
            .flatMap(HotKeyPreset.init(rawValue:)) ?? .none
        self.showsUsageFooter = defaults.object(forKey: Keys.usageFooter) as? Bool ?? true
        self.agentModels = modelStore.load()
    }
}
