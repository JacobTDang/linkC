extension SQLSchema {
    public static func createStatements(for tables: [Table]) -> String {
        guard !tables.isEmpty else { return "" }
        let names = Set(tables.map(\.name))
        var remaining = tables
        var emitted: Set<String> = []
        var statements: [String] = []
        var deferred: [(String, BoardColumn)] = []
        let ordered: (Table, Table) -> Bool = {
            ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name)
        }

        while !remaining.isEmpty {
            let ready = remaining.filter { table in
                table.columns.allSatisfy { column in
                    guard let target = column.references?.table else { return true }
                    return target == table.name || !names.contains(target) || emitted.contains(target)
                }
            }.sorted(by: ordered)
            let table: Table
            let isCycle: Bool
            if let first = ready.first { table = first; isCycle = false }
            else { table = remaining.sorted(by: ordered)[0]; isCycle = true }

            var deferredColumns: Set<String> = []
            if isCycle {
                for column in table.columns {
                    if let target = column.references?.table, names.contains(target), target != table.name, !emitted.contains(target) {
                        deferred.append((table.name, column))
                        deferredColumns.insert(column.name)
                    }
                }
            }
            statements.append(createStatement(table, omittingReferencesFor: deferredColumns))
            emitted.insert(table.name)
            remaining.removeAll { $0.name == table.name }
        }

        statements += deferred.compactMap { table, column in
            guard let reference = column.references else { return nil }
            return "ALTER TABLE \(quotedTable(table)) ADD FOREIGN KEY (\(quotedIfNeeded(column.name))) REFERENCES \(quotedTable(reference.table)) (\(quotedIfNeeded(reference.column)));"
        }
        return statements.joined(separator: "\n\n") + "\n"
    }

    private static func createStatement(_ table: Table, omittingReferencesFor omitted: Set<String>) -> String {
        let primaryKeys = table.columns.filter(\.pk)
        var lines = table.columns.map { column -> String in
            var line = "\(quotedIfNeeded(column.name)) \(column.type)"
            if column.pk && primaryKeys.count == 1 { line += " PRIMARY KEY" }
            if !column.nullable && !column.pk { line += " NOT NULL" }
            if column.unique { line += " UNIQUE" }
            if let defaultValue = column.defaultValue { line += " DEFAULT \(defaultValue)" }
            if let reference = column.references, !omitted.contains(column.name) {
                line += " REFERENCES \(quotedTable(reference.table)) (\(quotedIfNeeded(reference.column)))"
            }
            return "  \(line)"
        }
        if primaryKeys.count > 1 {
            lines.append("  PRIMARY KEY (\(primaryKeys.map { quotedIfNeeded($0.name) }.joined(separator: ", ")))")
        }
        return "CREATE TABLE \(quotedTable(table.name)) (\n\(lines.joined(separator: ",\n"))\n);"
    }

    private static func quotedTable(_ name: String) -> String {
        guard let dot = name.firstIndex(of: ".") else { return quotedIfNeeded(name) }
        let first = String(name[..<dot]), second = String(name[name.index(after: dot)...])
        guard !first.isEmpty, !second.isEmpty else { return quotedIfNeeded(name) }
        return "\(quotedIfNeeded(first)).\(quotedIfNeeded(second))"
    }
}
