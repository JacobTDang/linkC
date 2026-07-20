import Foundation

/// Data models for a parsed `kitten @ ls` tree (osWindows → tabs → windows).
/// The parser lives in the Kitty module; these types are the shared contract.

public struct KittyWindow: Sendable, Equatable {
    public let id: Int
    public let title: String
    public let cwd: String
    public let pid: Int
    public let isFocused: Bool
    public let needsAttention: Bool
    /// `user_vars["linkc_session"]`, the correlation key for a linkC-launched tab.
    public let linkcSession: String?

    public init(id: Int, title: String, cwd: String, pid: Int, isFocused: Bool, needsAttention: Bool, linkcSession: String?) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.isFocused = isFocused
        self.needsAttention = needsAttention
        self.linkcSession = linkcSession
    }
}

public struct KittyTab: Sendable, Equatable {
    public let id: Int
    public let title: String
    public let isActive: Bool
    public let isFocused: Bool
    public let windows: [KittyWindow]

    public init(id: Int, title: String, isActive: Bool, isFocused: Bool, windows: [KittyWindow]) {
        self.id = id
        self.title = title
        self.isActive = isActive
        self.isFocused = isFocused
        self.windows = windows
    }

    /// A linkC tab carries exactly one window; expose its correlation id.
    public var linkcSession: String? { windows.first(where: { $0.linkcSession != nil })?.linkcSession }
}

public struct KittyOSWindow: Sendable, Equatable {
    public let id: Int
    public let isFocused: Bool
    public let platformWindowId: Int?
    public let tabs: [KittyTab]

    public init(id: Int, isFocused: Bool, platformWindowId: Int?, tabs: [KittyTab]) {
        self.id = id
        self.isFocused = isFocused
        self.platformWindowId = platformWindowId
        self.tabs = tabs
    }
}

public extension Array where Element == KittyOSWindow {
    /// Flatten to all windows across all os-windows/tabs.
    var allWindows: [KittyWindow] { flatMap { $0.tabs.flatMap(\.windows) } }

    /// The `linkc_session` of the currently focused window, if any (for focus-aware notifications).
    var focusedLinkcSession: String? {
        for osw in self where osw.isFocused {
            for tab in osw.tabs where tab.isFocused {
                if let w = tab.windows.first(where: { $0.isFocused }) { return w.linkcSession }
            }
        }
        return nil
    }
}
