import Foundation

/// Where each tile sits. A component that carries a position keeps it; the rest fill the free
/// cells in name order, so the same map lays out the same way on every machine.
public enum WorkbenchLayout {
    /// Cells across before the grid wraps.
    public static let columns = 5

    public static func positions(for components: [SystemComponent]) -> [String: GridPoint] {
        var positions: [String: GridPoint] = [:]
        var taken: Set<String> = []
        for component in components {
            guard let at = component.at else { continue }
            positions[component.name] = at
            taken.insert("\(at.x),\(at.y)")
        }

        var cell = 0
        for component in components.filter({ $0.at == nil }).sorted(by: { $0.name < $1.name }) {
            while taken.contains("\(cell % columns),\(cell / columns)") { cell += 1 }
            let point = GridPoint(x: cell % columns, y: cell / columns)
            positions[component.name] = point
            taken.insert("\(point.x),\(point.y)")
            cell += 1
        }
        return positions
    }
}
