import Foundation

/// Ghost neighbours on a detail board: parts from the parent board that interact with the
/// detailed part, placed at the left or right edges and kept read-only.
public enum BoardGhosts {
    /// Syncs ghosts on a detail map against its parent board for the given part.
    /// Returns the detail map with its ghosts synced and placed, or nil if nothing changed.
    public static func sync(detail: BoardMap, parent: BoardMap, part partName: String) -> BoardMap? {
        let lowerPart = partName.lowercased()
        let parentPart = parent.components.first { $0.name.lowercased() == lowerPart }

        // Neighbours of `part` in `parent`: compare names lowercased.
        // Every component with an arrow into `part` is an `.in` neighbour.
        var inNeighbours: [BoardComponent] = []
        var inNames = Set<String>()
        for component in parent.components where component.name.lowercased() != lowerPart {
            if component.uses.keys.contains(where: { $0.lowercased() == lowerPart }) {
                inNeighbours.append(component)
                inNames.insert(component.name.lowercased())
            }
        }

        // Every target of `part`'s arrows that exists in `parent` is an `.out` neighbour, unless it's already `.in`.
        var outNeighbours: [BoardComponent] = []
        if let parentPart {
            for targetName in parentPart.uses.keys {
                let lowerTarget = targetName.lowercased()
                guard lowerTarget != lowerPart, !inNames.contains(lowerTarget) else { continue }
                if let targetComponent = parent.components.first(where: { $0.name.lowercased() == lowerTarget }) {
                    if !outNeighbours.contains(where: { $0.name.lowercased() == lowerTarget }) {
                        outNeighbours.append(targetComponent)
                    }
                }
            }
        }

        struct Neighbour {
            let component: BoardComponent
            let side: BoardGhostSide
        }

        var neighbours: [Neighbour] = []
        for neighbour in inNeighbours { neighbours.append(Neighbour(component: neighbour, side: .in)) }
        for neighbour in outNeighbours { neighbours.append(Neighbour(component: neighbour, side: .out)) }
        neighbours.sort { $0.component.name.lowercased() < $1.component.name.lowercased() }

        var map = detail
        var changed = false
        var neighbourNames = Set<String>()

        for neighbour in neighbours {
            let nNameLower = neighbour.component.name.lowercased()
            neighbourNames.insert(nNameLower)

            if let existingIndex = map.components.firstIndex(where: { $0.name.lowercased() == nNameLower }) {
                if map.components[existingIndex].outside != nil {
                    // Existing ghost: set kind and outside to neighbour's, stale to false.
                    if map.components[existingIndex].kind != neighbour.component.kind {
                        map.components[existingIndex].kind = neighbour.component.kind
                        changed = true
                    }
                    if map.components[existingIndex].outside != neighbour.side {
                        map.components[existingIndex].outside = neighbour.side
                        changed = true
                    }
                    if map.components[existingIndex].stale {
                        map.components[existingIndex].stale = false
                        changed = true
                    }
                }
                // Non-ghost part: leave it, inner part stands in.
            } else {
                let newGhost = BoardComponent(
                    name: neighbour.component.name,
                    kind: neighbour.component.kind,
                    place: BoardMap.notPlaced,
                    outside: neighbour.side
                )
                map.components.append(newGhost)
                changed = true
            }
        }

        // Every ghost that is no longer a neighbour and isn't yet stale: set stale = true, mark changed. Never remove one.
        for index in map.components.indices {
            if map.components[index].outside != nil {
                let ghostNameLower = map.components[index].name.lowercased()
                if !neighbourNames.contains(ghostNameLower) && !map.components[index].stale {
                    map.components[index].stale = true
                    changed = true
                }
            }
        }

        guard changed else { return nil }
        return BoardLayout.placedGhosts(map)
    }
}
