import SwiftUI
import LinkCKit

/// The floating toolbar at the bottom of the canvas.
struct BoardToolbar: View {
    @Bindable var board: BoardModel
    @Binding var lastKind: ComponentKind

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.select, glyph: "cursorarrow", title: "Select", key: "V")
            Menu {
                ForEach(ComponentKind.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.kinds, id: \.raw) { kind in
                            Button {
                                lastKind = kind
                                board.tool = .component(kind)
                            } label: {
                                Label(kind.raw.capitalized, systemImage: kind.glyph)
                            }
                        }
                    }
                }
            } label: {
                toolLabel(glyph: lastKind.glyph, title: "Component", key: "C", isOn: isComponentTool)
            } primaryAction: {
                board.tool = .component(lastKind)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            toolButton(.arrow, glyph: "arrow.right", title: "Arrow", key: "A")
            toolButton(.frame, glyph: "rectangle.dashed", title: "Frame", key: "F")
            toolButton(.note, glyph: "note.text", title: "Note", key: "N")
            toolButton(.text, glyph: "textformat", title: "Text", key: "T")
            Rectangle().fill(Theme.textTertiary.opacity(0.25)).frame(width: 1, height: 16).padding(.horizontal, 2)
            tidyUpButton
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.boardBox.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    private var isComponentTool: Bool {
        if case .component = board.tool { return true }
        return false
    }

    /// Rearranges the whole map by flow, as one undo step — disabled while the board refuses
    /// edits, or while there's nothing to arrange.
    private var tidyUpButton: some View {
        Button { board.tidyUp() } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars").font(.system(size: 11))
                Text("Tidy up").font(.system(size: 11))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(board.isLocked || board.isEmpty)
        .help("Tidy up — rearrange the whole map by flow")
    }

    private func toolButton(_ tool: BoardModel.Tool, glyph: String, title: String, key: String) -> some View {
        Button { board.tool = tool } label: {
            toolLabel(glyph: glyph, title: title, key: key, isOn: board.tool == tool)
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(glyph: String, title: String, key: String, isOn: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph).font(.system(size: 11))
            Text(title).font(.system(size: 11))
            Text(key).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
        }
        .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .help("\(title) (\(key))")
    }
}

/// The card beside a selected component. Opens on a snapshot of the component and never updates
/// it from further re-renders while it's open — an agent's change to a field the user hasn't
/// touched must go on showing what the user typed, not jump underneath it — so Done can commit
/// just the fields the user actually changed, leaving anything else exactly as it now is.
struct ComponentInspector: View {
    let livesIn: String
    let uses: [(target: String, label: String)]
    /// Commits only the fields the user changed, and the new name when it changed too; returns
    /// false when the board refused it, which keeps the card open.
    let commit: (BoardComponentFields, _ rename: String?) -> Bool
    /// The board's refusal reason, read only when this card's own Done is refused — never a
    /// stale reason left over from something else.
    let currentRefusal: () -> String?
    let close: () -> Void

    /// The component exactly as it was when the card opened — `@State` so it, like `draft`,
    /// ignores every later `init` this view's re-renders pass it, and never drifts.
    @State private var original: BoardComponent
    @State private var draft: BoardComponent
    @State private var refusal: String?
    @FocusState private var nameFocused: Bool

    init(component: BoardComponent, livesIn: String, uses: [(target: String, label: String)],
         commit: @escaping (BoardComponentFields, _ rename: String?) -> Bool, currentRefusal: @escaping () -> String?, close: @escaping () -> Void) {
        self.livesIn = livesIn
        self.uses = uses
        self.commit = commit
        self.currentRefusal = currentRefusal
        self.close = close
        _original = State(wrappedValue: component)
        _draft = State(wrappedValue: component)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                caption("Name")
                TextField("", text: $draft.name).focused($nameFocused)
            }
            VStack(alignment: .leading, spacing: 3) {
                caption("Kind")
                Picker("", selection: $draft.kind) {
                    ForEach(kinds, id: \.raw) { kind in
                        Label(kind.raw.capitalized, systemImage: kind.glyph).tag(kind)
                    }
                }
                .labelsHidden()
            }
            field("What it does", text: optional(\.does), prompt: "one line: what this is for")
            field("Reached by", text: optional(\.reachedBy), prompt: "DATABASE_URL, a URL, a host")
            field("Runs", text: optional(\.runs), prompt: "docker compose (db) — how linkC finds it running")
            Toggle("Still planned — doesn't exist yet", isOn: $draft.planned)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
            Divider()
            readOnly("Lives in", livesIn)
            readOnly("Uses", uses.isEmpty ? "nothing yet — drag an arrow from its side"
                     : uses.map { $0.label.isEmpty ? $0.target : "\($0.target) (\($0.label))" }.joined(separator: ", "))
            if let refusal {
                Text(refusal).font(.system(size: 10.5)).foregroundStyle(Theme.accent)
            }
            HStack {
                Spacer()
                Button("Done") {
                    if commit(changedFields, draft.name != original.name ? draft.name : nil) {
                        close()
                    } else {
                        refusal = currentRefusal()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 280)
        .onAppear { nameFocused = true }
    }

    /// Only the fields that differ from `original` — `nil` for the rest, so `updateComponent`
    /// leaves them exactly as they now are, whatever changed them since the card opened.
    /// `does`, `reachedBy` and `runs` compare with `?? ""` on both sides: typing into a field and
    /// then deleting it leaves `draft`'s value as `""`, which must not count as a change from a
    /// `nil` `original` — that would clear a value an agent set in the meantime, one the user
    /// never actually touched.
    private var changedFields: BoardComponentFields {
        BoardComponentFields(
            kind: draft.kind != original.kind ? draft.kind : nil,
            does: (draft.does ?? "") != (original.does ?? "") ? (draft.does ?? "") : nil,
            reachedBy: (draft.reachedBy ?? "") != (original.reachedBy ?? "") ? (draft.reachedBy ?? "") : nil,
            runs: (draft.runs ?? "") != (original.runs ?? "") ? (draft.runs ?? "") : nil,
            planned: draft.planned != original.planned ? draft.planned : nil)
    }

    /// The known kinds, plus this component's own kind when linkC does not know it — so a
    /// preserved custom kind is shown, and kept unless changed.
    private var kinds: [ComponentKind] {
        draft.kind.isKnown ? ComponentKind.known : ComponentKind.known + [draft.kind]
    }

    private func optional(_ keyPath: WritableKeyPath<BoardComponent, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            caption(title)
            TextField(prompt, text: text)
        }
    }

    private func caption(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
    }

    private func readOnly(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caption(title)
            Text(value).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A note being edited in place. Commits when focus leaves — and, since a notification click or
/// a tab switch can tear the Board down without ever delivering that focus-lost transition,
/// also on disappear, when there is still an unsaved change to lose.
struct NoteEditor: View {
    let commit: (String) -> Void
    private let original: String
    @State private var text: String
    @State private var closed = false
    @FocusState private var focused: Bool

    init(text: String, commit: @escaping (String) -> Void) {
        self.commit = commit
        self.original = text
        _text = State(wrappedValue: text)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.noteText)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(width: CGFloat(BoardGeometry.noteSize.x), height: CGFloat(BoardGeometry.noteSize.y))
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.noteFill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 1.5))
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused, !closed else { return }
                closed = true
                commit(text)
            }
            .onDisappear {
                guard !closed, text != original else { return }
                closed = true
                commit(text)
            }
    }
}

/// The board's small inline text field look: a `boardBox` fill and a coloured 1 pt border —
/// shared by `LineEditor` and `ArrowEditor`'s label and bits fields. Leaves the font to the
/// caller, since callers want different sizes and weights.
private struct BoardMiniField: ViewModifier {
    let width: CGFloat
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.boardBox))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(borderColor, lineWidth: 1))
    }
}

private extension View {
    func boardMiniField(width: CGFloat, borderColor: Color) -> some View {
        modifier(BoardMiniField(width: width, borderColor: borderColor))
    }
}

/// A single line being edited in place — a text, a frame's label, an arrow's label. Commits on
/// Return or when focus leaves. `commit` returns false when the board refused the value, which
/// keeps the editor open with what was typed; `refusal` is shown beneath it when that happens.
/// Also commits on disappear — a notification click or a tab switch can tear the Board down
/// without ever delivering the focus-lost transition — when there is still an unsaved change;
/// `closed` keeps that from ever running twice.
struct LineEditor: View {
    let font: Font
    let width: CGFloat
    let refusal: String?
    let commit: (String) -> Bool
    private let original: String
    @State private var text: String
    @State private var closed = false
    @FocusState private var focused: Bool

    init(text: String, font: Font, width: CGFloat, refusal: String? = nil, commit: @escaping (String) -> Bool) {
        self.font = font
        self.width = width
        self.refusal = refusal
        self.commit = commit
        self.original = text
        _text = State(wrappedValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("", text: $text)
                .font(font)
                .boardMiniField(width: width, borderColor: Theme.accent)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit(finish)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { finish() }
                }
                .onDisappear {
                    guard !closed, text != original else { return }
                    closed = true
                    _ = commit(text)
                }
            if let refusal {
                Text(refusal).font(.system(size: 9.5)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func finish() {
        guard !closed else { return }
        if commit(text) { closed = true }
    }
}

/// An arrow's label and style, edited together at the route's midpoint: the label as a text
/// field, plus a compact plain/conditional/control/bus picker and, for bus, a bits field (empty
/// unless the arrow already carries one — the field never invents 32). Return, in either text
/// field, commits — `commit` calls `BoardModel.setArrow` once, so the whole edit is one undo step
/// and a no-op when nothing changed. An empty bits field means nil; anything else must be a whole
/// number 1…4096, refused inline exactly as `LineEditor`'s commit is — the editor stays open and
/// shows why, instead of silently coercing "abc" or clamping "9999". So does focus leaving both
/// fields (a click on the picker doesn't take focus, so it never triggers this) — tracked as one
/// group so moving between the label and bits fields themselves never closes the editor early.
/// Also commits on disappear, for the same reasons `LineEditor` does, but only when bits still
/// parses — an invalid value left on the field when the view is torn down from outside is
/// dropped, never coerced into something that was never typed. Esc behaves exactly as it does for
/// `LineEditor`, since the label field is the same kind of field.
struct ArrowEditor: View {
    let commit: (_ label: String, _ style: BoardArrowStyle, _ bits: Int?) -> Void
    private let originalLabel: String
    private let originalStyle: BoardArrowStyle
    private let originalBitsText: String
    @State private var label: String
    @State private var style: BoardArrowStyle
    @State private var bitsText: String
    @State private var refusal: String?
    @State private var closed = false
    private enum Field: Hashable { case label, bits }
    @FocusState private var focusedField: Field?

    init(label: String, style: BoardArrowStyle, bits: Int?, commit: @escaping (String, BoardArrowStyle, Int?) -> Void) {
        self.commit = commit
        self.originalLabel = label
        self.originalStyle = style
        let bitsText = bits.map(String.init) ?? ""
        self.originalBitsText = bitsText
        _label = State(wrappedValue: label)
        _style = State(wrappedValue: style)
        _bitsText = State(wrappedValue: bitsText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $label)
                .font(.system(size: 10))
                .boardMiniField(width: 200, borderColor: Theme.accent)
                .focused($focusedField, equals: .label)
                .onAppear { focusedField = .label }
                .onSubmit(finish)
            Picker("", selection: $style) {
                Text("Plain").tag(BoardArrowStyle.plain)
                Text("Conditional").tag(BoardArrowStyle.conditional)
                Text("Control").tag(BoardArrowStyle.control)
                Text("Bus").tag(BoardArrowStyle.bus)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 200)
            if style == .bus {
                TextField("bits", text: $bitsText)
                    .font(.system(size: 10))
                    .boardMiniField(width: 60, borderColor: Color.white.opacity(0.15))
                    .focused($focusedField, equals: .bits)
                    .onSubmit(finish)
            }
            if let refusal {
                Text(refusal).font(.system(size: 9.5)).foregroundStyle(Theme.accent)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.boardBox.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil { finish() }
        }
        .onDisappear {
            guard !closed, label != originalLabel || style != originalStyle || (style == .bus && bitsText != originalBitsText) else { return }
            guard case .value(let bits) = parsedBits() else { return }
            closed = true
            commit(label, style, bits)
        }
    }

    private enum BitsParse { case value(Int?); case invalid(String) }

    /// `bitsText`, parsed: empty means nil; anything else must be a whole number 1…4096, or it is
    /// refused with the reason.
    private func parsedBits() -> BitsParse {
        guard style == .bus else { return .value(nil) }
        let trimmed = bitsText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .value(nil) }
        guard let value = Int(trimmed) else { return .invalid("bits must be a whole number") }
        guard (1...4096).contains(value) else { return .invalid("bits must be between 1 and 4096") }
        return .value(value)
    }

    private func finish() {
        guard !closed else { return }
        switch parsedBits() {
        case .value(let bits):
            closed = true
            commit(label, style, bits)
        case .invalid(let reason):
            refusal = reason
        }
    }
}

/// What double-clicking empty canvas offers.
struct QuickAddMenu: View {
    let add: (QuickAddChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(ComponentKind.known, id: \.raw) { kind in
                row(kind.raw.capitalized, glyph: kind.glyph) { add(.component(kind)) }
            }
            Divider().padding(.vertical, 3)
            row("Note", glyph: "note.text") { add(.note) }
            row("Text", glyph: "textformat") { add(.text) }
            row("Frame", glyph: "rectangle.dashed") { add(.frame) }
        }
        .padding(6)
        .frame(width: 170)
    }

    private func row(_ title: String, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: glyph)
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum QuickAddChoice {
    case component(ComponentKind)
    case note
    case text
    case frame
}

/// What linkC sees running that the map does not name.
struct SuggestionList: View {
    let suggestions: [MapSuggestion]
    let add: (MapSuggestion) -> Void
    let addAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions) { suggestion in
                HStack(spacing: 8) {
                    Image(systemName: suggestion.kind.glyph).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name).font(.system(size: 11.5, weight: .medium))
                        Text(suggestion.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Button("Add") { add(suggestion) }.font(.system(size: 11))
                }
            }
            if suggestions.count > 1 {
                Divider()
                Button("Add all \(suggestions.count)", action: addAll).font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
