public enum SQLSchema {
    public struct Table: Equatable, Sendable {
        public var name: String
        public var columns: [BoardColumn]
        public init(name: String, columns: [BoardColumn]) { self.name = name; self.columns = columns }
    }
    public struct Note: Equatable, Sendable {
        public var line: Int
        public var text: String
        public init(line: Int, text: String) { self.line = line; self.text = text }
    }
    public struct Parsed: Equatable, Sendable {
        public var tables: [Table]
        public var skipped: [Note]
        public var notModelled: [Note]
        public init(tables: [Table], skipped: [Note], notModelled: [Note]) {
            self.tables = tables; self.skipped = skipped; self.notModelled = notModelled
        }
    }
    public static func parse(_ sql: String) throws -> Parsed {
        var parser = SQLSchemaParser(sql: sql)
        return try parser.parse()
    }
    public static func quotedIfNeeded(_ name: String) -> String {
        let reserved = Set("all analyse analyze and any array as asc asymmetric both case cast check collate column constraint create current_catalog current_date current_role current_time current_timestamp current_user default deferrable desc distinct do else end except false fetch for foreign from grant group having in initially intersect into lateral leading limit localtime localtimestamp not null offset on only or order placing primary references returning select session_user some symmetric table then to trailing true union unique user using variadic when where window with".split(separator: " ").map(String.init))
        let chars = Array(name)
        let plain = !chars.isEmpty && (chars[0].isLowercase || chars[0] == "_")
            && chars.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
            && !reserved.contains(name)
        return plain ? name : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
