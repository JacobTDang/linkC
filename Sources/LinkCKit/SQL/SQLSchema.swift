/// Reads and writes the supported Postgres table-schema subset.
public enum SQLSchema {
    private static let reservedWords = Set(
        "all analyse analyze and any array as asc asymmetric both case cast check collate column constraint create current_catalog current_date current_role current_time current_timestamp current_user default deferrable desc distinct do else end except false fetch for foreign from grant group having in initially intersect into lateral leading limit localtime localtimestamp not null offset on only or order placing primary references returning select session_user some symmetric table then to trailing true union unique user using variadic when where window with"
            .split(separator: " ").map(String.init))
    /// A table and its columns, in source order.
    public struct Table: Equatable, Sendable {
        public var name: String
        public var columns: [BoardColumn]
        public init(name: String, columns: [BoardColumn]) {
            self.name = name
            self.columns = columns
        }
    }
    /// A skipped or unmodelled piece of SQL and its one-based source line.
    public struct Note: Equatable, Sendable {
        public var line: Int
        public var text: String
        public init(line: Int, text: String) {
            self.line = line
            self.text = text
        }
    }
    /// Tables read from SQL together with every construct that was not kept.
    public struct Parsed: Equatable, Sendable {
        public var tables: [Table]
        public var skipped: [Note]
        public var notModelled: [Note]
        public init(tables: [Table], skipped: [Note], notModelled: [Note]) {
            self.tables = tables
            self.skipped = skipped
            self.notModelled = notModelled
        }
    }
    /// Reads Postgres schema SQL into table models and diagnostic notes.
    public static func parse(_ sql: String) throws -> Parsed {
        var parser = SQLSchemaParser(sql: sql)
        return try parser.parse()
    }
    /// Quotes an identifier unless it is a safe, non-reserved lowercase ASCII name.
    public static func quotedIfNeeded(_ name: String) -> String {
        let chars = Array(name)
        let plain =
            !chars.isEmpty && (chars[0].isASCIILowercase || chars[0] == "_")
            && chars.allSatisfy { $0.isASCIILowercase || $0.isASCIIDigit || $0 == "_" }
            && !reservedWords.contains(name)
        return plain ? name : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// The table-kind parts of `map`, lowercased-name order, ready for `createStatements(for:)`.
    /// Planned tables and planned columns are included — only `kind` decides membership.
    public static func tables(in map: BoardMap) -> [Table] {
        map.components
            .filter { $0.kind == .table }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { Table(name: $0.name, columns: $0.columns) }
    }
}

/// ASCII character classes used by SQL identifier quoting.
extension Character {
    fileprivate var isASCIILowercase: Bool { ("a"..."z").contains(self) }
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
