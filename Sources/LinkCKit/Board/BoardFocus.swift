import Foundation

/// What Focus keeps visible: a pinned part with its direct neighbours both ways, or a pinned
/// arrow with its two ends.
public enum BoardFocus {
    public struct Visible: Equatable, Sendable {
        public let parts: Set<String>
        public let arrows: Set<BoardModel.ArrowKey>
    }

    public static func visible(aroundPart name: String, in map: BoardMap) -> Visible {
        let key = name.lowercased()
        var parts: Set<String> = []
        var arrows: Set<BoardModel.ArrowKey> = []
        for component in map.components {
            for target in component.uses.keys {
                let touches = component.name.lowercased() == key || target.lowercased() == key
                guard touches else { continue }
                arrows.insert(BoardModel.ArrowKey(from: component.name, to: target))
                parts.insert(component.name)
                parts.insert(map.components.first { $0.name.lowercased() == target.lowercased() }?.name ?? target)
            }
            if component.name.lowercased() == key { parts.insert(component.name) }
        }
        return Visible(parts: parts, arrows: arrows)
    }

    public static func visible(aroundArrow key: BoardModel.ArrowKey, in map: BoardMap) -> Visible {
        let name: (String) -> String = { raw in map.components.first { $0.name.lowercased() == raw.lowercased() }?.name ?? raw }
        return Visible(parts: [name(key.from), name(key.to)], arrows: [key])
    }
}
