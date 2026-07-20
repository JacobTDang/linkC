import Foundation

/// Parses `kitten @ ls` JSON into the shared `KittyOSWindow` tree.
///
/// The real payload carries many fields we don't care about (layout state, scrollback
/// sizing, etc.); the raw `Decodable` mirror types below only declare the ones we use,
/// so `JSONDecoder` simply ignores the rest.
public enum KittyLsParser {
    public static func parse(_ data: Data) throws -> [KittyOSWindow] {
        let raw: [RawOSWindow]
        do {
            raw = try JSONDecoder().decode([RawOSWindow].self, from: data)
        } catch {
            throw LinkCError.parse("failed to parse `kitten @ ls` output: \(error)")
        }
        return raw.map(KittyOSWindow.init)
    }
}

// MARK: - Raw wire shapes (snake_case keys, mapped to the Core domain types)

private struct RawOSWindow: Decodable {
    let id: Int
    let isFocused: Bool
    let platformWindowId: Int?
    let tabs: [RawTab]

    enum CodingKeys: String, CodingKey {
        case id, tabs
        case isFocused = "is_focused"
        case platformWindowId = "platform_window_id"
    }
}

private struct RawTab: Decodable {
    let id: Int
    let title: String
    let isActive: Bool
    let isFocused: Bool
    let windows: [RawWindow]

    enum CodingKeys: String, CodingKey {
        case id, title, windows
        case isActive = "is_active"
        case isFocused = "is_focused"
    }
}

private struct RawWindow: Decodable {
    let id: Int
    let title: String
    let cwd: String
    let pid: Int
    let isFocused: Bool
    let needsAttention: Bool
    let userVars: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, pid
        case isFocused = "is_focused"
        case needsAttention = "needs_attention"
        case userVars = "user_vars"
    }
}

// MARK: - Raw → domain mapping

private extension KittyOSWindow {
    init(_ raw: RawOSWindow) {
        self.init(
            id: raw.id,
            isFocused: raw.isFocused,
            platformWindowId: raw.platformWindowId,
            tabs: raw.tabs.map(KittyTab.init)
        )
    }
}

private extension KittyTab {
    init(_ raw: RawTab) {
        self.init(
            id: raw.id,
            title: raw.title,
            isActive: raw.isActive,
            isFocused: raw.isFocused,
            windows: raw.windows.map(KittyWindow.init)
        )
    }
}

private extension KittyWindow {
    init(_ raw: RawWindow) {
        self.init(
            id: raw.id,
            title: raw.title,
            cwd: raw.cwd,
            pid: raw.pid,
            isFocused: raw.isFocused,
            needsAttention: raw.needsAttention,
            linkcSession: raw.userVars?["linkc_session"]
        )
    }
}
