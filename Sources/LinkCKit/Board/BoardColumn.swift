public struct BoardColumnReference: Equatable, Hashable, Sendable {
    public var table: String
    public var column: String

    public init(table: String, column: String) {
        self.table = table
        self.column = column
    }

    public init?(parsing text: String) {
        guard let dot = text.lastIndex(of: ".") else { return nil }
        let table = String(text[..<dot])
        let column = String(text[text.index(after: dot)...])
        guard !table.isEmpty, !column.isEmpty else { return nil }
        self.init(table: table, column: column)
    }

    public var text: String { "\(table).\(column)" }
}

public struct BoardColumn: Equatable, Sendable {
    public var name: String
    public var type: String
    public var pk: Bool
    public var nullable: Bool
    public var unique: Bool
    public var defaultValue: String?
    public var references: BoardColumnReference?
    public var planned: Bool

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
}
