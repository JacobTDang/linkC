import Foundation

/// Where each tile sits. A component that carries a position keeps it; the rest fill the free
/// cells in name order, so the same map lays out the same way on every machine.
public enum WorkbenchLayout {
    /// Cells across before the grid wraps.
    public static let columns = 5

    public static func positions(for components: [SystemComponent]) -> [String: GridPoint] {
        var positions: [String: GridPoint] = [:]
        var taken: Set<GridPoint> = []
        var unplaced: [SystemComponent] = []

        // Name order first, so a cell contested by two components always goes to the same one
        // regardless of how the file lists them, and so the losing component joins the fill
        // queue at the point its name order gives it.
        for component in components.sorted(by: { $0.name < $1.name }) {
            guard let at = component.at, !taken.contains(at) else {
                unplaced.append(component)
                continue
            }
            positions[component.name] = at
            taken.insert(at)
        }

        var cell = 0
        for component in unplaced {
            while taken.contains(GridPoint(x: cell % columns, y: cell / columns)) { cell += 1 }
            let point = GridPoint(x: cell % columns, y: cell / columns)
            positions[component.name] = point
            taken.insert(point)
            cell += 1
        }
        return positions
    }
}
