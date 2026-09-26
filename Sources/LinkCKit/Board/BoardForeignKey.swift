/// One column's foreign key: the table and column it's on, and the table and column it points to.
/// Derived, never stored twice — a table's foreign keys always come from its own columns'
/// `references` (see `BoardColumn`), never from a separate list on the table or a `uses` arrow.
public struct BoardForeignKey: Hashable, Sendable {
    public var table: String
    public var column: String
    public var refTable: String
    public var refColumn: String

    public init(table: String, column: String, refTable: String, refColumn: String) {
        self.table = table
        self.column = column
        self.refTable = refTable
        self.refColumn = refColumn
    }

    /// Every column with `references` on a `table`-kind part of `map`, sorted by (table, column),
    /// both lowercased — deterministic regardless of file order or casing. Includes a ghost
    /// table's own columns: this only lists what a column's `references` says, never whether
    /// anything is drawn for it — `BoardRouter.foreignKeyRoutes`/`foreignKeyStubs` decide that.
    public static func all(in map: BoardMap) -> [BoardForeignKey] {
        map.components
            .filter { $0.kind == .table }
            .flatMap { component in
                component.columns.compactMap { column -> BoardForeignKey? in
                    guard let reference = column.references else { return nil }
                    return BoardForeignKey(
                        table: component.name, column: column.name,
                        refTable: reference.table, refColumn: reference.column)
                }
            }
            .sorted { ($0.table.lowercased(), $0.column.lowercased()) < ($1.table.lowercased(), $1.column.lowercased()) }
    }
}
