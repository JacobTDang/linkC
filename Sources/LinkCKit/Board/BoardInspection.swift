import Foundation

/// What a hover card and the docked inspector show for an arrow or a part, read from the map.
/// Rows order by the other end's name, lowercased, so a card never reshuffles.
public enum BoardInspection {
    public struct Row: Equatable, Sendable {
        /// The arrow's label, or the other end's name when it has none.
        public let signal: String
        public let bits: Int?
        public let other: String
        public let style: BoardArrowStyle
        public var isControl: Bool { style == .control || style == .conditional }
    }

    public struct Part: Equatable, Sendable {
        public let name: String
        public let kind: ComponentKind
        public let planned: Bool
        public let does: String?
        public let outside: BoardGhostSide?
        public let inputs: [Row]
        public let outputs: [Row]

        public var isGhost: Bool { outside != nil }

        public init(name: String, kind: ComponentKind, planned: Bool, does: String?, outside: BoardGhostSide? = nil, inputs: [Row], outputs: [Row]) {
            self.name = name
            self.kind = kind
            self.planned = planned
            self.does = does
            self.outside = outside
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    public struct Arrow: Equatable, Sendable {
        public let from: String
        public let to: String
        public let label: String
        public let bits: Int?
        public let style: BoardArrowStyle
        /// The ends whose status is planned, source first.
        public let plannedEnds: [String]
    }

    public static func part(_ name: String, in map: BoardMap) -> Part? {
        let key = name.lowercased()
        guard let part = map.components.first(where: { $0.name.lowercased() == key }) else { return nil }
        let outputs = part.uses.map { target, arrow in
            Row(signal: arrow.label.isEmpty ? target : arrow.label, bits: arrow.bits, other: target, style: arrow.style)
        }
        var inputs: [Row] = []
        for source in map.components {
            for (target, arrow) in source.uses where target.lowercased() == key {
                inputs.append(Row(signal: arrow.label.isEmpty ? source.name : arrow.label, bits: arrow.bits, other: source.name, style: arrow.style))
            }
        }
        let order: (Row, Row) -> Bool = { ($0.other.lowercased(), $0.signal) < ($1.other.lowercased(), $1.signal) }
        return Part(name: part.name, kind: part.kind, planned: part.planned, does: part.does, outside: part.outside,
                    inputs: inputs.sorted(by: order), outputs: outputs.sorted(by: order))
    }

    public static func arrow(_ key: BoardModel.ArrowKey, in map: BoardMap) -> Arrow? {
        guard let source = map.components.first(where: { $0.name.lowercased() == key.from.lowercased() }),
              let arrowData = source.uses.first(where: { $0.key.lowercased() == key.to.lowercased() })
        else { return nil }
        let target = arrowData.key
        let arrow = arrowData.value
        let targetPart = map.components.first { $0.name.lowercased() == target.lowercased() }
        var planned: [String] = []
        if source.planned { planned.append(source.name) }
        if targetPart?.planned == true { planned.append(targetPart!.name) }
        return Arrow(from: source.name, to: targetPart?.name ?? target, label: arrow.label, bits: arrow.bits,
                     style: arrow.style, plannedEnds: planned)
    }
}
