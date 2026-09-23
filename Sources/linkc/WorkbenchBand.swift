import SwiftUI
import LinkCKit

/// A project's system board: its components as tiles you drag, and what linkC found running
/// that the map does not name. Every rule lives in `WorkbenchModel`; this draws it.
struct WorkbenchBand: View {
    let workspacePath: String
    let model: AppModel

    @State private var workbench: WorkbenchModel
    @State private var editing: SystemComponent?
    @State private var showingSuggestions = false

    private static let cell = CGSize(width: 132, height: 46)
    private static let gap: CGFloat = 8

    init(workspacePath: String, model: AppModel) {
        self.workspacePath = workspacePath
        self.model = model
        _workbench = State(wrappedValue: WorkbenchModel(store: SystemMapStore(workspacePath: workspacePath)))
    }

    private var isOpen: Bool { model.sidebarState.isWorkbenchOpen(workspacePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isOpen {
                content
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .task {
            workbench.load()
            workbench.reconcile(with: model.discoveredThings(in: workspacePath))
        }
        .onDisappear { workbench.saveNow() }
        .popover(item: $editing) { component in
            ComponentEditor(component: component, workbench: workbench) { editing = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                let opening = !isOpen
                model.sidebarState.setWorkbenchOpen(workspacePath, opening)
                // Statuses were last reconciled in `.task`, which only ever runs once — without
                // this, something that started or stopped while the board was collapsed would
                // still show its old status the moment the board expands again.
                if opening {
                    workbench.reconcile(with: model.discoveredThings(in: workspacePath))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("SYSTEM")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            if !workbench.suggestions.isEmpty {
                Button { showingSuggestions = true } label: {
                    Text("\(workbench.suggestions.count) running, not on the map")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingSuggestions) { suggestionList }
            }
        }
    }

    /// The board's three ways of not being a plain, editable grid — kept visually distinct so
    /// each reads as what it is:
    /// - `.failed`: the map could not be read at all. The board is locked; nothing else shows.
    /// - `writeFailure`: the map in memory is fine, but the last save did not land. The board
    ///   stays open and editable; this is a retryable notice, not a lock.
    /// - `refusal`: an edit was rejected (a name already in use). Transient, and never blocks
    ///   the board — it just explains why the edit you just tried did not take.
    @ViewBuilder
    private var content: some View {
        switch workbench.state {
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.statusError)
                .lineLimit(2)
        case .empty, .loaded:
            if workbench.map.components.isEmpty {
                HStack(spacing: 8) {
                    Text("No system map for this project yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Button("Start one") {
                        workbench.startMap()
                        add(kind: .service)
                    }
                    .font(.system(size: 11))
                }
                .frame(height: 60, alignment: .leading)
            } else {
                board
                if let writeFailure = workbench.writeFailure {
                    HStack(spacing: 6) {
                        Label(writeFailure, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.contextWarn)
                            .lineLimit(2)
                        Button("Retry") { workbench.saveNow() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.contextWarn)
                    }
                }
                if let refusal = workbench.refusal {
                    Text(refusal)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                palette
            }
        }
    }

    /// Scrolls rather than clips: the model can place a tile in any row (only columns are
    /// bounded), so every row the map produces must stay reachable, not cut off past the third.
    private var board: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(workbench.map.components) { component in
                    let point = workbench.positions[component.name] ?? GridPoint(x: 0, y: 0)
                    ComponentTile(
                        component: component,
                        status: workbench.statuses[component.name],
                        onEdit: { editing = component },
                        onRemove: { workbench.remove(component.name) },
                        onDrop: { translation in
                            // The model decides the landing cell — clamping it into the grid's
                            // columns and away from whatever tile is already there — so the file
                            // it writes and the board it draws can never disagree.
                            workbench.move(component.name, to: GridPoint(
                                x: point.x + Int((translation.width / (Self.cell.width + Self.gap)).rounded()),
                                y: point.y + Int((translation.height / (Self.cell.height + Self.gap)).rounded())))
                        })
                    .frame(width: Self.cell.width, height: Self.cell.height)
                    .offset(
                        x: CGFloat(point.x) * (Self.cell.width + Self.gap),
                        y: CGFloat(point.y) * (Self.cell.height + Self.gap))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: fullBoardHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: visibleBoardHeight, alignment: .topLeading)
    }

    private var fullBoardHeight: CGFloat {
        let rows = (workbench.positions.values.map(\.y).max() ?? 0) + 1
        return CGFloat(rows) * (Self.cell.height + Self.gap)
    }

    private var visibleBoardHeight: CGFloat {
        let rows = (workbench.positions.values.map(\.y).max() ?? 0) + 1
        return CGFloat(min(rows, 3)) * (Self.cell.height + Self.gap)
    }

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(ComponentKind.known, id: \.raw) { kind in
                Button { add(kind: kind) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: glyph(for: kind)).font(.system(size: 9))
                        Text(kind.raw).font(.system(size: 10))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Add a \(kind.raw) you mean to build")
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(workbench.suggestions) { suggestion in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name).font(.system(size: 11, weight: .medium))
                        Text(suggestion.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Button("Add") {
                        workbench.add(SystemComponent(name: suggestion.name, kind: suggestion.kind))
                        workbench.reconcile(with: model.discoveredThings(in: workspacePath))
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    /// A component you add by hand starts intended: you are describing something you mean to
    /// build, and it becomes present when discovery finds it.
    private func add(kind: ComponentKind) {
        var name = "new-\(kind.raw)"
        var suffix = 2
        while workbench.map.components.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            name = "new-\(kind.raw)-\(suffix)"
            suffix += 1
        }
        let component = SystemComponent(name: name, kind: kind, intended: true)
        workbench.add(component)
        editing = component
    }

    fileprivate static func glyphName(for kind: ComponentKind) -> String {
        switch kind {
        case .database: return "cylinder.split.1x2"
        case .cache: return "bolt.horizontal"
        case .queue: return "tray.full"
        case .storage: return "externaldrive"
        case .host: return "server.rack"
        case .external: return "cloud"
        default: return "shippingbox"
        }
    }

    private func glyph(for kind: ComponentKind) -> String { Self.glyphName(for: kind) }
}

/// One component. Solid when it is real, outlined when it is only intended, dimmed when linkC
/// looked for it and did not find it.
private struct ComponentTile: View {
    let component: SystemComponent
    let status: ComponentStatus?
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onDrop: (CGSize) -> Void

    @State private var drag: CGSize = .zero

    private var isMissing: Bool { status == .missing && !component.intended }

    /// A component the map still calls intended, but that discovery actually found, must not be
    /// drawn dashed while also showing the running dot — that contradicts itself. The evidence
    /// wins: it is drawn present, and only the tooltip notes the map still calls it intended.
    private var drawnAsIntended: Bool { component.intended && status != .present }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: WorkbenchBand.glyphName(for: component.kind))
                .font(.system(size: 11))
                .foregroundStyle(isMissing ? Theme.textTertiary : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(component.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isMissing ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                if let reachedBy = component.reachedBy, !reachedBy.isEmpty {
                    Text(reachedBy)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if status == .present {
                Circle().fill(Theme.statusRunning).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(drawnAsIntended ? Color.clear : Theme.hover))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(
                    drawnAsIntended ? Theme.textTertiary : .clear,
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .opacity(isMissing ? 0.55 : 1)
        .offset(drag)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    drag = .zero
                    onDrop(value.translation)
                })
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Remove", role: .destructive, action: onRemove)
        }
        .help(helpText)
    }

    private var helpText: String {
        var parts: [String] = [component.kind.raw]
        if let runs = component.runs, !runs.isEmpty { parts.append("runs \(runs)") }
        if !component.usedBy.isEmpty { parts.append("used by \(component.usedBy.joined(separator: ", "))") }
        switch status {
        case .present: parts.append("running now")
        case .missing: parts.append("linkC looked for this and did not find it")
        case .unchecked, nil: parts.append("linkC cannot check this one")
        }
        if drawnAsIntended {
            parts.append("intended — does not exist yet")
        } else if component.intended {
            parts.append("the map still marks this intended")
        }
        return parts.joined(separator: " · ")
    }
}

/// Editing one component's fields.
private struct ComponentEditor: View {
    @State var component: SystemComponent
    let workbench: WorkbenchModel
    let onClose: () -> Void

    @State private var usedByText: String = ""

    private let original: String

    init(component: SystemComponent, workbench: WorkbenchModel, onClose: @escaping () -> Void) {
        _component = State(wrappedValue: component)
        self.workbench = workbench
        self.onClose = onClose
        original = component.name
        _usedByText = State(wrappedValue: component.usedBy.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("name", text: $component.name)
            Picker("kind", selection: Binding(
                get: { component.kind.raw },
                set: { component.kind = ComponentKind($0) })) {
                    ForEach(ComponentKind.known, id: \.raw) { Text($0.raw).tag($0.raw) }
                }
            TextField("reached by", text: Binding(
                get: { component.reachedBy ?? "" }, set: { component.reachedBy = $0 }))
            TextField("runs", text: Binding(
                get: { component.runs ?? "" }, set: { component.runs = $0 }))
            TextField("used by (comma separated)", text: $usedByText)
            Toggle("intended — does not exist yet", isOn: $component.intended)
            if let refusal = workbench.refusal {
                Text(refusal)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
            HStack {
                Spacer()
                Button("Done") {
                    component.usedBy = usedByText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    workbench.update(original, to: component)
                    // A refusal (a name already in use) leaves the edit unapplied: close only
                    // when it actually landed, so a refused rename never throws away what was
                    // typed — the fields stay exactly as the user left them, reason visible above.
                    if workbench.refusal == nil {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 300)
    }
}
