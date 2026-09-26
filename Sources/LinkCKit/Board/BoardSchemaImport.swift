import Foundation

/// Turns a parsed SQL schema into ordinary `BoardEditStep`s, so importing a database's schema is
/// one call to `BoardEdit.apply`. Nothing is deleted: design-only tables and columns stay planned.
public enum BoardSchemaImport {
    /// What one import did: how many tables were newly added, how many existing tables were
    /// reconciled with the SQL, how many board-only tables were marked planned because the SQL no
    /// longer names them, and how many SQL constructs the parser itself already reported as not
    /// kept (`skipped`) or not modelled (`notModelled`) — carried through unchanged from
    /// `SQLSchema.Parsed`, since import neither fixes nor hides either list.
    public struct Summary: Equatable, Sendable {
        public var added: Int
        public var updated: Int
        public var markedPlanned: Int
        public var skipped: Int
        public var notModelled: Int

        public init(added: Int, updated: Int, markedPlanned: Int, skipped: Int, notModelled: Int) {
            self.added = added
            self.updated = updated
            self.markedPlanned = markedPlanned
            self.skipped = skipped
            self.notModelled = notModelled
        }
    }

    /// `parsed`'s tables reconciled against `map`'s own `.table`-kind parts, and what that
    /// reconciliation did. For each table `parsed` names, in `parsed.tables`' own order:
    /// - a **non-ghost** existing part by that name, kind `.table`: an `update` step whose
    ///   `columns` is the SQL's columns (not planned) followed by every column already on the
    ///   part whose name isn't among the SQL's (forced planned) — counted as `updated`;
    /// - otherwise: an `add` step, kind `.table`, the SQL's columns exactly — counted as `added`.
    /// Then, for every **non-ghost**, `.table`-kind part already on the board that no parsed table
    /// matched (sorted by lowercased name): an `update` step marking it, and every one of its own
    /// columns, planned — counted as `markedPlanned`. Ghost components (`outside != nil`) are left
    /// alone entirely — never matched against, never swept.
    public static func plan(for parsed: SQLSchema.Parsed, into map: BoardMap) -> (steps: [BoardEditStep], summary: Summary) {
        var result: [BoardEditStep] = []
        var added = 0
        var updated = 0
        var markedPlanned = 0
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
                updated += 1
            } else {
                let fields = BoardComponentFields(kind: .table, columns: table.columns)
                result.append(.add(table.name, fields, place: nil))
                added += 1
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
            markedPlanned += 1
        }

        let summary = Summary(
            added: added, updated: updated, markedPlanned: markedPlanned,
            skipped: parsed.skipped.count, notModelled: parsed.notModelled.count)
        return (result, summary)
    }

    /// `plan(for:into:).steps` — kept as its own entry point since it's what an import actually
    /// applies; `BoardModel.importSchema` wants the summary alongside it, from the same pass.
    public static func steps(for parsed: SQLSchema.Parsed, into map: BoardMap) -> [BoardEditStep] {
        plan(for: parsed, into: map).steps
    }
}
