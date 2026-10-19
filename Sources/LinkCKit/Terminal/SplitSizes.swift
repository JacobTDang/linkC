import Foundation

/// How a split's grid divides its space once the user has resized its panes: each row's share of the
/// grid's height, and each pane's share of its row's width. The rows follow `SplitLayout.rows`, and the
/// sizes belong to positions, not terminals. Every share list holds positive fractions that add up to 1.
/// Pure value type.
public struct SplitSizes: Codable, Equatable, Sendable {
    /// The narrowest a pane gets, in points: the smallest a terminal stays usable at.
    public static let minPaneWidth: Double = 120
    /// The shortest a pane gets, in points.
    public static let minPaneHeight: Double = 80
    /// How far a stored share list may add up away from 1 and still be read.
    static let tolerance = 0.001

    /// The number of panes these sizes were made for.
    public let paneCount: Int
    /// Each row's share of the grid's height, top to bottom.
    public private(set) var rows: [Double]
    /// Per row, each pane's share of the row's width, left to right.
    public private(set) var columns: [[Double]]

    private init(paneCount: Int, rows: [Double], columns: [[Double]]) {
        self.paneCount = paneCount
        self.rows = rows
        self.columns = columns
    }

    /// The even grid of `paneCount` panes: every row the same height, every pane in a row the same width.
    public static func even(for paneCount: Int) -> SplitSizes {
        let layout = SplitLayout.rows(for: paneCount)
        return SplitSizes(paneCount: paneCount, rows: evenShares(layout.count), columns: layout.map(evenShares))
    }

    /// Whether these sizes describe a grid of `paneCount` panes.
    public func fits(paneCount: Int) -> Bool { self.paneCount == paneCount }

    /// The boundary between pane `divider` and pane `divider + 1` of `row` moved `distance` points
    /// (positive is right) in a row whose panes take `rowWidth` points between them. Only those two
    /// panes change. The boundary stops where either would fall below `minWidth`, and does not move
    /// when the two together are narrower than two minimums.
    public func resizingColumns(inRow row: Int, divider: Int, by distance: Double, rowWidth: Double,
                                minWidth: Double = SplitSizes.minPaneWidth) -> SplitSizes {
        precondition(columns.indices.contains(row) && divider >= 0 && divider + 1 < columns[row].count,
                     "no divider \(divider) in row \(row) of a \(paneCount)-pane grid")
        guard let shares = Self.moving(columns[row], boundary: divider, by: distance, length: rowWidth,
                                       minimum: minWidth) else { return self }
        var next = self
        next.columns[row] = shares
        return next
    }

    /// The boundary between the two rows moved `distance` points (positive is down) in a grid whose
    /// rows take `gridHeight` points between them, clamped as `resizingColumns` clamps. A one-row grid
    /// has nothing to resize.
    public func resizingRows(by distance: Double, gridHeight: Double,
                             minHeight: Double = SplitSizes.minPaneHeight) -> SplitSizes {
        guard rows.count == 2,
              let shares = Self.moving(rows, boundary: 0, by: distance, length: gridHeight, minimum: minHeight)
        else { return self }
        var next = self
        next.rows = shares
        return next
    }

    /// `row`'s panes back to the same width.
    public func evenedRow(_ row: Int) -> SplitSizes {
        precondition(columns.indices.contains(row), "no row \(row) in a \(paneCount)-pane grid")
        var next = self
        next.columns[row] = Self.evenShares(columns[row].count)
        return next
    }

    /// The rows back to the same height.
    public func evenedRows() -> SplitSizes {
        var next = self
        next.rows = Self.evenShares(rows.count)
        return next
    }

    /// The points `length` leaves for `count` panes once the `gap` between each two is taken out.
    /// Never negative.
    public static func paneSpace(_ length: Double, count: Int, gap: Double) -> Double {
        max(0, length - gap * Double(max(0, count - 1)))
    }

    private static func evenShares(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(count), count: count)
    }

    /// `shares` with the boundary after share `boundary` moved `distance` points along `length`, so that
    /// neither neighbour falls below `minimum`. nil when the two together hold less than two minimums.
    private static func moving(_ shares: [Double], boundary: Int, by distance: Double, length: Double,
                               minimum: Double) -> [Double]? {
        let pair = (shares[boundary] + shares[boundary + 1]) * length
        guard length > 0, pair >= 2 * minimum else { return nil }
        let first = min(max(shares[boundary] * length + distance, minimum), pair - minimum)
        var next = shares
        next[boundary] = first / length
        next[boundary + 1] = (pair - first) / length
        return next
    }

    private enum CodingKeys: String, CodingKey { case paneCount, rows, columns }

    /// Stored sizes are read only when they describe a grid: a pane count `SplitLayout` lays out, share
    /// lists of the lengths its rows give, and positive shares that add up to 1 within `tolerance`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paneCount = try container.decode(Int.self, forKey: .paneCount)
        let rows = try container.decode([Double].self, forKey: .rows)
        let columns = try container.decode([[Double]].self, forKey: .columns)
        let layout = SplitLayout.rows(for: paneCount)
        guard (2...SplitLayout.maxPanes).contains(paneCount), rows.count == layout.count,
              columns.map(\.count) == layout, ([rows] + columns).allSatisfy(Self.isShareList) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "rows \(rows) and columns \(columns) don't describe a grid of \(paneCount) panes"))
        }
        self.init(paneCount: paneCount, rows: rows, columns: columns)
    }

    /// Positive fractions that add up to 1, within `tolerance`.
    private static func isShareList(_ shares: [Double]) -> Bool {
        shares.allSatisfy { $0 > 0 && $0.isFinite } && abs(shares.reduce(0, +) - 1) <= tolerance
    }
}
