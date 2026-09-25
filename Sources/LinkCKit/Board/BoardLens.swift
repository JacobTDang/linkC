import Foundation

/// Which arrows the Board shows at full strength. The others fade and ignore hover, and every
/// part stays visible.
public enum BoardLens: String, Codable, Sendable, CaseIterable {
    case all, data, control

    public func includes(_ style: BoardArrowStyle) -> Bool {
        switch self {
        case .all: return true
        case .data: return style == .bus || style == .plain
        case .control: return style == .control || style == .conditional
        }
    }
}
