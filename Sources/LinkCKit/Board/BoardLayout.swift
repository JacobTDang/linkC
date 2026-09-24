import Foundation

/// Arranges a whole map by the flow of its arrows: frames flow left to right and stack at the
/// same stage; components flow in columns inside each frame; notes go to the right. Pure,
/// nonisolated and deterministic — the same map always yields the same layout, and applying it
/// twice gives the same result as applying it once. Ties break by lowercased name throughout.
public enum BoardLayout {
    private static let columnGapInFrame = 136
    private static let columnGapBetweenClusters = 184
    private static let rowStep = 132
    private static let framePadding = 24
    private static let frameTitleBand = 34
    private static let origin = BoardPoint(x: 40, y: 40)
    private static let notesGap = 48
    private static let noteStackGap = 24

    /// A cluster of components: one per frame, keyed by its label, plus a virtual cluster (label
    /// `nil`) for components whose place names no frame.
    private struct Cluster {
        var label: String?
        var components: [BoardComponent]
    }

    /// A cluster's computed size and where each of its components sits, in columns and rows.
    private struct ClusterLayout {
        var width: Int
        var height: Int
        var positions: [String: (col: Int, row: Int)]
    }

    public static func arranged(_ map: BoardMap) -> BoardMap {
        var result = map
        let clusters = buildClusters(map)

        var clusterRects: [String?: BoardRect] = [:]
        if !clusters.isEmpty {
            let nameToComponent = Dictionary(uniqueKeysWithValues: map.components.map { ($0.name.lowercased(), $0) })

            // Cluster graph: an edge C→D when some component in C uses one in D.
            var clusterEdges: [String?: Set<String?>] = [:]
            for cluster in clusters {
                for component in cluster.components {
                    for used in component.uses.keys {
                        guard let usedComponent = nameToComponent[used.lowercased()] else { continue }
                        let target = effectivePlace(usedComponent, frames: map.frames)
                        guard target != cluster.label else { continue }
                        clusterEdges[cluster.label, default: []].insert(target)
                    }
                }
            }
            let clusterAdjacency = clusterEdges.mapValues { Array($0) }

            let clusterLabels = clusters.map(\.label)
            let clusterOrder = processingOrder(clusterLabels)
            let (rank, dag) = longestPathRanks(nodes: clusterLabels, order: clusterOrder, edges: clusterAdjacency)
            let predecessors = reversed(dag)

            var layouts: [String?: ClusterLayout] = [:]
            for cluster in clusters { layouts[cluster.label] = clusterLayout(for: cluster) }

            var byRank: [Int: [String?]] = [:]
            for label in clusterLabels { byRank[rank[label] ?? 0, default: []].append(label) }

            var x = origin.x
            for r in byRank.keys.sorted() {
                let ordered = orderByBarycentre(byRank[r] ?? [], predecessors: predecessors, rects: clusterRects)
                var y = origin.y
                for label in ordered {
                    let size = layouts[label] ?? ClusterLayout(width: 0, height: 0, positions: [:])
                    let rect = BoardRect(x: x, y: y, w: size.width, h: size.height)
                    clusterRects[label] = rect
                    y = rect.maxY + rowStep
                }
                let widest = (byRank[r] ?? []).map { layouts[$0]?.width ?? 0 }.max() ?? 0
                x += widest + columnGapBetweenClusters
            }

            // Components and frames: a component sits inside its cluster's rect, at its column
            // and row; each frame's rect becomes its cluster's rect. The virtual cluster has none.
            for cluster in clusters {
                guard let rect = clusterRects[cluster.label], let layout = layouts[cluster.label] else { continue }
                if let label = cluster.label, let frameIndex = result.frames.firstIndex(where: { $0.label == label }) {
                    result.frames[frameIndex].rect = rect.snapped
                }
                for component in cluster.components {
                    guard let position = layout.positions[component.name],
                          let index = result.components.firstIndex(where: { $0.name == component.name }) else { continue }
                    let at = BoardPoint(
                        x: rect.x + framePadding + position.col * (BoardGeometry.componentSize.x + columnGapInFrame),
                        y: rect.y + frameTitleBand + position.row * rowStep)
                    result.components[index].at = at.snapped
                }
            }
        }

        // Notes: one column to the right of everything, stacked in file order.
        let diagramMaxX = clusterRects.values.map(\.maxX).max() ?? origin.x
        let notesX = diagramMaxX + notesGap
        var noteY = origin.y
        for index in result.notes.indices {
            let rect = BoardRect(x: notesX, y: noteY, w: BoardGeometry.noteSize.x, h: BoardGeometry.noteSize.y)
            result.notes[index].at = rect.origin.snapped
            noteY = rect.maxY + noteStackGap
        }

        // Texts: kept where they are, moved clear only if they now overlap a box, frame or note.
        let boxes = result.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            + result.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        let frameRects = result.frames.compactMap(\.rect)
        for index in result.texts.indices {
            let rect = BoardGeometry.rect(of: result.texts[index])
            guard boxes.contains(where: { $0.intersects(rect) }) || frameRects.contains(where: { $0.intersects(rect) }) else { continue }
            result.texts[index].at = BoardGeometry.elementDrop(rect, otherElements: boxes, frames: frameRects).origin.snapped
        }

        return result
    }

    // MARK: - Clusters

    /// The label a component's cluster is keyed by: its own place when that names a real frame,
    /// else `nil` — the virtual "Not placed" cluster.
    private static func effectivePlace(_ component: BoardComponent, frames: [BoardFrame]) -> String? {
        frames.contains { $0.label == component.place } ? component.place : nil
    }

    private static func buildClusters(_ map: BoardMap) -> [Cluster] {
        var byPlace: [String: [BoardComponent]] = [:]
        var virtual: [BoardComponent] = []
        for component in map.components {
            if let place = effectivePlace(component, frames: map.frames) {
                byPlace[place, default: []].append(component)
            } else {
                virtual.append(component)
            }
        }
        var clusters = map.frames.map { frame in Cluster(label: frame.label, components: byPlace[frame.label] ?? []) }
        if !virtual.isEmpty { clusters.append(Cluster(label: nil, components: virtual)) }
        return clusters
    }

    /// Sizes a cluster and places its components in columns and rows.
    private static func clusterLayout(for cluster: Cluster) -> ClusterLayout {
        let (positions, cols, rows) = columnsAndRows(for: cluster.components)
        let width = 2 * framePadding + cols * BoardGeometry.componentSize.x + (cols - 1) * columnGapInFrame
        let height = frameTitleBand + rows * BoardGeometry.componentSize.y + (rows - 1) * (rowStep - BoardGeometry.componentSize.y) + framePadding
        return ClusterLayout(width: width, height: height, positions: positions)
    }

    /// Column = longest path from an internal source, along the cluster's own arrows. Rows are
    /// ordered by name, then four barycentre passes settle them by their neighbours' rows.
    private static func columnsAndRows(for components: [BoardComponent]) -> (positions: [String: (col: Int, row: Int)], cols: Int, rows: Int) {
        guard !components.isEmpty else { return ([:], 1, 1) }
        let names = Set(components.map(\.name))
        var directed: [String: Set<String>] = [:]
        for component in components {
            for used in component.uses.keys where used != component.name && names.contains(used) {
                directed[component.name, default: []].insert(used)
            }
        }
        var undirected: [String: Set<String>] = [:]
        for (from, tos) in directed {
            for to in tos {
                undirected[from, default: []].insert(to)
                undirected[to, default: []].insert(from)
            }
        }

        let allNames = components.map(\.name)
        let order = processingOrder(allNames.map { Optional($0) }).map { $0! }
        let (columnRank, _) = longestPathRanks(nodes: allNames, order: order, edges: directed.mapValues(Array.init))

        let cols = (columnRank.values.max() ?? 0) + 1
        var byColumn: [[String]] = Array(repeating: [], count: cols)
        for name in allNames.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            byColumn[columnRank[name] ?? 0].append(name)
        }

        var rowOf: [String: Int] = [:]
        func reindex(_ col: Int) { for (row, name) in byColumn[col].enumerated() { rowOf[name] = row } }
        for col in byColumn.indices { reindex(col) }

        func barycentreKey(_ name: String, adjacent: Int) -> (Double, String) {
            let lowerKey = name.lowercased()
            guard adjacent >= 0, adjacent < cols else { return (Double(rowOf[name] ?? 0), lowerKey) }
            let neighbours = (undirected[name] ?? []).filter { columnRank[$0] == adjacent }
            guard !neighbours.isEmpty else { return (Double(rowOf[name] ?? 0), lowerKey) }
            let mean = neighbours.compactMap { rowOf[$0] }.reduce(0.0) { $0 + Double($1) } / Double(neighbours.count)
            return (mean, lowerKey)
        }

        func pass(leftToRight: Bool) {
            let columnsInOrder = leftToRight ? Array(byColumn.indices) : Array(byColumn.indices.reversed())
            for col in columnsInOrder {
                let adjacent = leftToRight ? col - 1 : col + 1
                let keyed = byColumn[col].map { ($0, barycentreKey($0, adjacent: adjacent)) }
                byColumn[col] = keyed.sorted { $0.1 < $1.1 }.map(\.0)
                reindex(col)
            }
        }
        pass(leftToRight: true)
        pass(leftToRight: false)
        pass(leftToRight: true)
        pass(leftToRight: false)

        var positions: [String: (col: Int, row: Int)] = [:]
        for (col, names) in byColumn.enumerated() {
            for (row, name) in names.enumerated() { positions[name] = (col: col, row: row) }
        }
        let rows = byColumn.map(\.count).max() ?? 1
        return (positions, cols, max(1, rows))
    }

    /// Clusters at the same rank, ordered by the mean y-centre of the (already placed) clusters
    /// in lower ranks they connect to, falling back to the label.
    private static func orderByBarycentre(
        _ labels: [String?], predecessors: [String?: [String?]], rects: [String?: BoardRect]
    ) -> [String?] {
        func key(_ label: String?) -> (Double, String) {
            let labelKey = label?.lowercased() ?? "\u{FFFF}"
            let ys = (predecessors[label] ?? []).compactMap { rects[$0]?.center.y }.map(Double.init)
            guard !ys.isEmpty else { return (0, labelKey) }
            return (ys.reduce(0, +) / Double(ys.count), labelKey)
        }
        return labels.sorted { key($0) < key($1) }
    }

    // MARK: - Cycle-broken longest-path ranking, shared by clusters and columns

    /// `nodes` processed in DESCENDING lowercased order (ties among real labels; `nil` — the
    /// virtual cluster — always sorts last), used both to pick DFS roots and to order each node's
    /// own edges, so the DFS is fully deterministic.
    private static func processingOrder(_ labels: [String?]) -> [String?] {
        let real = Set(labels.compactMap { $0 }).sorted { $0.lowercased() > $1.lowercased() }
        var order: [String?] = real.map { $0 }
        if labels.contains(where: { $0 == nil }) { order.append(nil) }
        return order
    }

    /// Breaks cycles with a DFS over `nodes` in `order`: an edge to a node already on the current
    /// DFS stack is reversed. `rank(C)` is then the longest path from a source in that acyclic
    /// graph. Returns the rank per node and the acyclic graph itself (for barycentre lookups).
    private static func longestPathRanks<Node: Hashable>(
        nodes: [Node], order: [Node], edges: [Node: [Node]]
    ) -> (rank: [Node: Int], dag: [Node: [Node]]) {
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var onStack: Set<Node> = []
        var visited: Set<Node> = []
        var dag: [Node: [Node]] = [:]

        func dfs(_ u: Node) {
            onStack.insert(u)
            visited.insert(u)
            let neighbours = (edges[u] ?? []).sorted { (position[$0] ?? .max) < (position[$1] ?? .max) }
            for v in neighbours {
                if onStack.contains(v) {
                    dag[v, default: []].append(u)
                } else if !visited.contains(v) {
                    dag[u, default: []].append(v)
                    dfs(v)
                } else {
                    dag[u, default: []].append(v)
                }
            }
            onStack.remove(u)
        }
        for u in order where !visited.contains(u) { dfs(u) }

        var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        for (_, tos) in dag { for v in tos { indegree[v, default: 0] += 1 } }
        var rank = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        var remaining = indegree
        var frontier = nodes.filter { indegree[$0] == 0 }
        while !frontier.isEmpty {
            var next: [Node] = []
            for u in frontier {
                for v in dag[u] ?? [] {
                    rank[v] = max(rank[v] ?? 0, (rank[u] ?? 0) + 1)
                    remaining[v]! -= 1
                    if remaining[v] == 0 { next.append(v) }
                }
            }
            frontier = next
        }
        return (rank, dag)
    }

    private static func reversed<Node: Hashable>(_ dag: [Node: [Node]]) -> [Node: [Node]] {
        var result: [Node: [Node]] = [:]
        for (u, tos) in dag { for v in tos { result[v, default: []].append(u) } }
        return result
    }
}
