import Foundation

/// Turns a parsed SQL schema into ordinary `BoardEditStep`s, so importing a database's schema is
/// one call to `BoardEdit.apply`. Nothing is deleted: design-only tables and columns stay planned.
public enum BoardSchemaImport {
    /// Reconciles parsed tables against the board's own table parts, preserving design-only data.
    public static func steps(for parsed: SQLSchema.Parsed, into map: BoardMap) -> [BoardEditStep] {
        var result: [BoardEditStep] = []
        let byLowercasedName = Dictionary(
            uniqueKeysWithValues: map.components
                .filter { $0.outside == nil }
                .map { ($0.name.lowercased(), $0) })
        var matchedNames: Set<String> = []

        for table in parsed.tables {
            let key = table.name.lowercased()
            if let existing = byLowercasedName[key], existing.kind == .table {
                matchedNames.insert(key)
                let databaseNames = Set(table.columns.map { $0.name.lowercased() })
                let designOnly = existing.columns
                    .filter { !databaseNames.contains($0.name.lowercased()) }
                    .map { column -> BoardColumn in
                        var plannedColumn = column
                        plannedColumn.planned = true
                        return plannedColumn
                    }
                let fields = BoardComponentFields(
                    planned: false,
                    columns: table.columns + designOnly)
                result.append(.update(existing.name, fields, place: nil, rename: nil))
            } else {
                let fields = BoardComponentFields(kind: .table, columns: table.columns)
                result.append(.add(table.name, fields, place: nil))
            }
        }

        let missing = map.components
            .filter {
                $0.kind == .table &&
                    $0.outside == nil &&
                    !matchedNames.contains($0.name.lowercased())
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        for component in missing {
            let plannedColumns = component.columns.map { column -> BoardColumn in
                var plannedColumn = column
                plannedColumn.planned = true
                return plannedColumn
            }
            let fields = BoardComponentFields(planned: true, columns: plannedColumns)
            result.append(.update(component.name, fields, place: nil, rename: nil))
        }

        return result
    }
}
