import SwiftUI
import LinkCKit

/// `error`'s own useful message, including refusals that do not conform to `LocalizedError`.
func boardEditErrorText(_ error: Error) -> String {
    if let refusal = error as? BoardEditRefusal {
        return refusal.reason
    }
    if let linkCError = error as? LinkCError {
        return linkCError.localizedDescription
    }
    return error.localizedDescription
}

/// What a hover card or the docked inspector is showing: a part or an arrow, read once from the
/// map through `BoardInspection` — never the map itself, so this view never reaches back into
/// model state.
enum BoardInspectionContent: Equatable {
    case part(BoardInspection.Part)
    case arrow(BoardInspection.Arrow)
}

/// Which pinned or hovered thing an inspection targets — a part by name, or an arrow by its key.
/// Only these two `BoardModel.Element` cases ever inspect; a dedicated type keeps every switch
/// here exhaustive over just them.
enum BoardInspectionTarget: Equatable {
    case part(String)
    case arrow(BoardModel.ArrowKey)
}

/// The body both the hover card and the docked inspector show — a part's name, kind and IN/OUT
/// rows, or an arrow's ends, label and style. No chrome of its own; callers wrap it in a card or a
/// docked panel.
struct BoardInspectionBody: View {
    let content: BoardInspectionContent
    var parentTitle: String? = nil

    var body: some View {
        switch content {
        case .part(let part): partBody(part)
        case .arrow(let arrow): arrowBody(arrow)
        }
    }

    @ViewBuilder
    private func partBody(_ part: BoardInspection.Part) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(part.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if part.isGhost {
                Text("From the overview · \(parentTitle ?? "overview")")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(kindCaption(part))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let does = part.does, !does.isEmpty {
                Text(does)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !part.inputs.isEmpty { section("IN", rows: part.inputs, isInput: true) }
            if !part.outputs.isEmpty { section("OUT", rows: part.outputs, isInput: false) }
        }
    }

    /// `defaultSubLine(for:)`, else the bare kind name, with `· PLANNED` appended while the part
    /// doesn't exist yet.
    private func kindCaption(_ part: BoardInspection.Part) -> String {
        let base = BoardShape.defaultSubLine(for: part.kind) ?? part.kind.raw.uppercased()
        return part.planned ? "\(base) · PLANNED" : base
    }

    private func section(_ title: String, rows: [BoardInspection.Row], isInput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            ForEach(rows.indices, id: \.self) { index in row(rows[index], isInput: isInput) }
        }
    }

    private func row(_ row: BoardInspection.Row, isInput: Bool) -> some View {
        let tint = row.isControl ? Theme.boardGold : Theme.textPrimary
        return HStack(spacing: 4) {
            Text(row.signal)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            // The width, bold — or a blank the same width holds, so every row's other-end text
            // still lines up in a column whether or not that row carries a width.
            Text(row.bits.map(String.init) ?? "")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(minWidth: 20, alignment: .leading)
            Spacer(minLength: 6)
            Text((isInput ? "← " : "→ ") + row.other)
                .font(.system(size: 11))
                .foregroundStyle(row.isControl ? Theme.boardGold : Theme.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func arrowBody(_ arrow: BoardInspection.Arrow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(arrow.from) → \(arrow.to)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(styleLine(arrow))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            if !arrow.plannedEnds.isEmpty {
                Text("Planned: \(arrow.plannedEnds.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// `label · <descriptor>`, or just the descriptor with no label — the descriptor is
    /// `<bits>-bit bus` for a bus with a width, else the style's own name.
    private func styleLine(_ arrow: BoardInspection.Arrow) -> String {
        let descriptor: String
        if arrow.style == .bus, let bits = arrow.bits {
            descriptor = "\(bits)-bit bus"
        } else {
            descriptor = styleName(arrow.style)
        }
        return arrow.label.isEmpty ? descriptor : "\(arrow.label) · \(descriptor)"
    }

    private func styleName(_ style: BoardArrowStyle) -> String {
        switch style {
        case .plain: return "Plain"
        case .conditional: return "Conditional"
        case .control: return "Control"
        case .bus: return "Bus"
        }
    }
}

/// The transient hover card: a dark plane, a hairline border, 10 pt radius — the approved
/// mockup's card treatment. Never intercepts the pointer; it's a tooltip, not a control.
struct BoardHoverCard: View {
    let content: BoardInspectionContent
    var parentTitle: String? = nil
    static let width: CGFloat = 240

    var body: some View {
        BoardInspectionBody(content: content, parentTitle: parentTitle)
            .padding(12)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.boardCardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .allowsHitTesting(false)
    }
}

/// The docked inspector: a 260 pt panel at the Board's right edge, full height, outside the
/// zoomed content so it neither pans nor zooms. Its own opaque plane means pointer events over it
/// never reach the canvas beneath.
struct BoardDockedInspector: View {
    let content: BoardInspectionContent
    var parentTitle: String? = nil
    let edit: () -> Void
    var goDeeper: (() -> Void)? = nil
    let close: () -> Void
    /// The pinned table's editable columns, or nil for every other inspected item.
    var columns: BoardColumnsGridInput? = nil
    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    BoardInspectionBody(content: content, parentTitle: parentTitle)
                    if let columns {
                        BoardColumnsGrid(input: columns).id(columns.tableName)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.boardCardFill)
        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1) }
        .shadow(color: .black.opacity(0.4), radius: 14, x: -2)
        .contentShape(Rectangle())
    }

    private var isGhostPart: Bool {
        if case .part(let part) = content {
            return part.isGhost
        }
        return false
    }

    private var isPart: Bool {
        if case .part = content { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isGhostPart {
                Button("Edit…") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .disabled(true)
                    .help("Change it on the overview")
            } else {
                Button("Edit…", action: edit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                if isPart, let goDeeper {
                    Button("↳ Go deeper", action: goDeeper)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The table data and commit closure handed from the docked inspector to its columns grid.
struct BoardColumnsGridInput {
    let tableName: String
    let columns: [BoardColumn]
    let referenceOptions: [String]
    let commit: ([BoardColumn]) throws -> Void
}

/// A pinned table's editable columns, with every accepted change committed as one board edit.
struct BoardColumnsGrid: View {
    let input: BoardColumnsGridInput

    @State private var rows: [BoardColumn]
    @State private var refusal: String?

    init(input: BoardColumnsGridInput) {
        self.input = input
        _rows = State(wrappedValue: input.columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COLUMNS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            // Keyed by name, which the board keeps unique: a row's draft moves with its column
            // through a reorder or delete instead of staying at a position.
            ForEach(Array(rows.enumerated()), id: \.element.name) { index, column in
                BoardColumnRow(
                    column: column,
                    referenceOptions: input.referenceOptions,
                    isFirst: index == 0,
                    isLast: index == rows.count - 1,
                    commit: { commitRow(at: index, to: $0) },
                    moveUp: { move(index, by: -1) },
                    moveDown: { move(index, by: 1) },
                    delete: { removeRow(at: index) })
            }
            Button("+ Add column", action: addRow)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            if let refusal {
                Text(refusal)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.contextWarn)
            }
        }
        // An undo, an agent's edit or an import changes the columns from outside; the grid shows
        // them, so its next commit never writes back what was there before.
        .onChange(of: input.columns) { _, columns in
            rows = columns
            refusal = nil
        }
    }

    private func commitRow(at index: Int, to column: BoardColumn) -> Bool {
        var proposed = rows
        proposed[index] = column
        return attemptCommit(proposed)
    }

    private func move(_ index: Int, by delta: Int) {
        var proposed = rows
        proposed.swapAt(index, index + delta)
        attemptCommit(proposed)
    }

    private func removeRow(at index: Int) {
        var proposed = rows
        proposed.remove(at: index)
        attemptCommit(proposed)
    }

    private func addRow() {
        let name = BoardColumn.nextColumnName(avoiding: rows)
        attemptCommit(rows + [BoardColumn(name: name, type: "text")])
    }

    @discardableResult
    private func attemptCommit(_ proposed: [BoardColumn]) -> Bool {
        do {
            try input.commit(proposed)
            rows = proposed
            refusal = nil
            return true
        } catch {
            refusal = boardEditErrorText(error)
            return false
        }
    }
}

/// One editable table-column row, including constraints, references, ordering, and deletion.
private struct BoardColumnRow: View {
    let column: BoardColumn
    let referenceOptions: [String]
    let isFirst: Bool
    let isLast: Bool
    let commit: (BoardColumn) -> Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void

    private static let commonTypes = [
        "uuid", "text", "bigint", "integer", "boolean", "timestamptz", "jsonb", "numeric", "date", "varchar(255)",
    ]

    @State private var draft: BoardColumn

    init(
        column: BoardColumn,
        referenceOptions: [String],
        isFirst: Bool,
        isLast: Bool,
        commit: @escaping (BoardColumn) -> Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        delete: @escaping () -> Void
    ) {
        self.column = column
        self.referenceOptions = referenceOptions
        self.isFirst = isFirst
        self.isLast = isLast
        self.commit = commit
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.delete = delete
        _draft = State(wrappedValue: column)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                TextField("name", text: $draft.name).onSubmit(submit)
                typeField
                reorderAndDelete
            }
            HStack(spacing: 6) {
                toggle("PK", isOn: draft.pk, set: setPK)
                toggle("NN", isOn: !draft.nullable, set: setNotNull).disabled(draft.pk)
                toggle("UQ", isOn: draft.unique) {
                    draft.unique = $0
                    submit()
                }
                referencesMenu
            }
            TextField(
                "default",
                text: Binding(
                    get: { draft.defaultValue ?? "" },
                    set: { draft.defaultValue = $0.isEmpty ? nil : $0 }))
                .onSubmit(submit)
        }
        .font(.system(size: 11))
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
        // The same column changed from outside (an undo, say): the draft shows the new value.
        .onChange(of: column) { _, updated in
            draft = updated
        }
    }

    private var typeField: some View {
        HStack(spacing: 2) {
            TextField("type", text: $draft.type).onSubmit(submit)
            Menu {
                ForEach(Self.commonTypes, id: \.self) { type in
                    Button(type) {
                        draft.type = type
                        submit()
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var referencesMenu: some View {
        Menu {
            Button("None") {
                draft.references = nil
                submit()
            }
            ForEach(referenceOptions, id: \.self) { option in
                Button(option) {
                    draft.references = BoardColumnReference(parsing: option)
                    submit()
                }
            }
        } label: {
            Text(draft.references?.text ?? "None")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
    }

    private var reorderAndDelete: some View {
        HStack(spacing: 2) {
            Button(action: moveUp) { Image(systemName: "chevron.up") }.disabled(isFirst)
            Button(action: moveDown) { Image(systemName: "chevron.down") }.disabled(isLast)
            Button(action: delete) { Image(systemName: "xmark") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(Theme.textTertiary)
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button {
            set(!isOn)
        } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(isOn ? Theme.accent.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func setPK(_ value: Bool) {
        draft.pk = value
        if value {
            draft.nullable = false
        }
        submit()
    }

    private func setNotNull(_ value: Bool) {
        draft.nullable = !value
        submit()
    }

    private func submit() {
        if !commit(draft) {
            draft = column
        }
    }
}
