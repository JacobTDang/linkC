import Foundation

/// The table and column named by a SQL foreign-key reference.
public struct BoardColumnReference: Equatable, Hashable, Sendable {
    /// The referenced table, including a non-public schema when present.
    public var table: String
    /// The referenced column.
    public var column: String

    public init(table: String, column: String) {
        self.table = table
        self.column = column
    }

    /// Reads `table.column`, splitting at the last dot so a schema may prefix the table.
    public init?(parsing text: String) {
        guard let dot = text.lastIndex(of: ".") else { return nil }
        let table = String(text[..<dot])
        let column = String(text[text.index(after: dot)...])
        guard !table.isEmpty, !column.isEmpty else { return nil }
        self.init(table: table, column: column)
    }

    /// The reference written as `table.column`.
    public var text: String { "\(table).\(column)" }
}

/// One ordered column in a table component.
public struct BoardColumn: Equatable, Sendable {
    /// The column's SQL identifier.
    public var name: String
    /// The column's SQL type text.
    public var type: String
    /// Whether this column belongs to the table's primary key.
    public var pk: Bool
    /// Whether this column accepts null values.
    public var nullable: Bool
    /// Whether this column has a single-column unique constraint.
    public var unique: Bool
    /// The SQL expression used as this column's default.
    public var defaultValue: String?
    /// The table column referenced by this column's foreign key.
    public var references: BoardColumnReference?
    /// Whether this column exists only in the planned design.
    public var planned: Bool

    /// Creates a column, making every primary-key column non-nullable.
    public init(
        name: String, type: String, pk: Bool = false, nullable: Bool = true, unique: Bool = false,
        defaultValue: String? = nil, references: BoardColumnReference? = nil, planned: Bool = false
    ) {
        self.name = name
        self.type = type
        self.pk = pk
        self.nullable = pk ? false : nullable
        self.unique = unique
        self.defaultValue = defaultValue
        self.references = references
        self.planned = planned
    }

    /// Validates the structural rules shared by board-file columns and typed column edits.
    public static func validate(_ columns: [BoardColumn], context: String) throws {
        var seen: Set<String> = []
        for column in columns {
            guard !column.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LinkCError.parse("\(context) has a column with no \"name\"")
            }
            guard !column.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LinkCError.parse("\(context) column \"\(column.name)\" has no \"type\"")
            }
            guard seen.insert(column.name.lowercased()).inserted else {
                throw LinkCError.parse("\(context) names column \"\(column.name)\" twice")
            }
            if let reference = column.references {
                let tableIsBlank = reference.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let columnIsBlank = reference.column.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard !tableIsBlank, !columnIsBlank else {
                    throw LinkCError.parse(
                        "\(context) column \"\(column.name)\" has \"references\" \"\(reference.text)\" but it is not table.column")
                }
            }
        }
    }

    /// The first "column_N" name (N starting at 1) not already used by `existing`, ignoring case —
    /// what the app's "+ Add column" names a freshly appended column.
    public static func nextColumnName(avoiding existing: [BoardColumn]) -> String {
        let used = Set(existing.map { $0.name.lowercased() })
        var number = 1
        while used.contains("column_\(number)") {
            number += 1
        }
        return "column_\(number)"
    }

    /// Every other table's columns in `map`, as "table.column", sorted by (table, column) both
    /// lowercased — what the app's references `Menu` lists after "None".
    public static func referenceOptions(in map: BoardMap, excludingTable table: String) -> [String] {
        map.components
            .filter { $0.kind == .table && $0.name.lowercased() != table.lowercased() }
            .flatMap { component in
                component.columns.map {
                    BoardColumnReference(table: component.name, column: $0.name)
                }
            }
            .sorted {
                ($0.table.lowercased(), $0.column.lowercased()) <
                    ($1.table.lowercased(), $1.column.lowercased())
            }
            .map(\.text)
    }
}
