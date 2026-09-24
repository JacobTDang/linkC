import AppKit
import SwiftUI
import LinkCKit

/// The Board's canvas. The dot grid, frames and arrows are one `Canvas` pass; components, notes,
/// texts and frame handles are views on one layer that pans and zooms as a whole. Only what is
/// on screen is built, and a drag moves one offset until it is dropped.
struct BoardCanvas: View {
    @Bindable var board: BoardModel
    let projectPath: String
    let sidebarState: SidebarState
    /// Loads the board; called once when the canvas appears, before the viewport is placed.
    let prepare: () -> Void

    static let space = "board"

    @State private var viewport: BoardViewport = .initial
    @State private var size: CGSize = .zero
    @State private var canvasFrame: CGRect = .zero
    /// Screen offset of the elements being dragged, until they are dropped.
    @State private var dragOffset: CGSize = .zero
    @State private var dragging: Set<BoardModel.Element> = []
    /// The selection box being drawn, in screen points.
    @State private var marquee: CGRect?
    @State private var spaceHeld = false
    @State private var panStart: BoardViewport?
    /// A frame being resized: its label and the proposed rect, until release.
    @State private var resizing: (label: String, rect: BoardRect)?
    @State private var input = BoardInput()
    @State private var lastKind: ComponentKind = .service
    /// The component whose inspector card is open.
    @State private var inspecting: String?
    @State private var editingNote: UUID?
    @State private var editingText: UUID?
    @State private var editingFrame: String?
    /// Why the frame label editor's own last commit was refused — never a stale reason from
    /// something else.
    @State private var frameRenameRefusal: String?
    @State private var editingArrow: BoardModel.ArrowKey?
    /// A component under the pointer, whose side handles are showing.
    @State private var hovered: String?
    /// An arrow being drawn: the component it leaves and the pointer, in screen points.
    @State private var arrowDraft: (from: String, to: CGPoint)?
    /// A frame being drawn, in screen points.
    @State private var frameDraft: CGRect?
    /// Where the quick-add menu opens and what it places, in canvas points — fixed at the
    /// double-click, so a pan or zoom while it's open doesn't move where the choice lands.
    @State private var quickAddAt: CGPoint?
    @State private var showingSuggestions = false
    @State private var systemDraft = ""
    @FocusState private var systemFocused: Bool
    /// What the last outside change touched, glowing while `glowOpacity` fades back to 0.
    @State private var glowing: Set<BoardModel.Element> = []
    @State private var glowOpacity = 0.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                background
                drawing
                elements
                overlays
            }
            .background(WindowReader { input.window = $0 })
            .coordinateSpace(.named(Self.space))
            .clipped()
            .onAppear {
                size = geometry.size
                canvasFrame = geometry.frame(in: .global)
                prepare()
                placeViewport()
                wireInput()
                input.start()
            }
            .onChange(of: geometry.size) { _, newSize in
                size = newSize
                canvasFrame = geometry.frame(in: .global)
            }
            .onDisappear {
                input.stop()
                sidebarState.setBoardViewport(viewport, for: projectPath)
            }
        }
        .background(Theme.boardBackground)
        .onChange(of: board.outsideChange?.id) { _, _ in outsideChangeArrived() }
    }

    /// Lights up what the change touched at full opacity, then — on the next runloop turn, so
    /// SwiftUI has actually rendered that full-opacity frame first — fades it out over 2 seconds.
    /// `glowing` clears itself once the fade completes, unless a newer change has since landed.
    private func outsideChangeArrived() {
        glowing = board.outsideChange?.elements ?? []
        glowOpacity = 1
        let change = board.outsideChange?.id
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 2)) {
                glowOpacity = 0
            } completion: {
                if board.outsideChange?.id == change { glowing = [] }
            }
        }
    }

    // MARK: - Layers

    /// Empty canvas: tapping clears the selection; dragging draws a selection box, or pans while
    /// Space is held.
    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged(backgroundDragChanged)
                    .onEnded(backgroundDragEnded))
            .onTapGesture(count: 2, coordinateSpace: .named(Self.space)) { location in
                backgroundDoubleTapped(at: location)
            }
            .onTapGesture(count: 1, coordinateSpace: .named(Self.space)) { location in
                backgroundTapped(at: location)
            }
    }

    private var drawing: some View {
        Canvas { context, canvasSize in
            drawGrid(in: &context, size: canvasSize)
            drawFrames(in: &context)
            drawArrows(in: &context)
            if let marquee {
                let path = Path(roundedRect: marquee, cornerRadius: 3)
                context.fill(path, with: .color(Theme.accent.opacity(0.08)))
                context.stroke(path, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1)
            }
            if let frameDraft {
                let path = Path(roundedRect: frameDraft, cornerRadius: 12 * viewport.zoom)
                context.stroke(path, with: .color(Theme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            if let arrowDraft, let source = board.map.components.first(where: { $0.name == arrowDraft.from }),
               let rect = componentRect(source) {
                let start = viewport.toScreen(CGPoint(x: Double(rect.center.x), y: Double(rect.center.y)))
                var path = Path()
                path.move(to: start)
                path.addLine(to: arrowDraft.to)
                context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    private var elements: some View {
        let visible = visibleCanvasRect()
        return ZStack(alignment: .topLeading) {
            ForEach(board.map.frames.filter { frameRect($0)?.intersects(visible) == true }) { frame in
                frameHandles(frame)
                frameGlow(frame)
            }
            ForEach(board.map.components.filter { componentRect($0)?.intersects(visible) == true }) { component in
                if let at = component.at {
                    ComponentBox(component: component, status: board.statuses[component.name],
                                 isSelected: board.selection.contains(.component(component.name)))
                        .overlay { if hovered == component.name && board.tool == .select && dragging.isEmpty { handles(for: component.name) } }
                        .overlay { glow(.component(component.name), cornerRadius: 10) }
                        .onHover { inside in
                            if inside { hovered = component.name } else if hovered == component.name { hovered = nil }
                        }
                        .popover(isPresented: Binding(get: { inspecting == component.name }, set: { if !$0 { inspecting = nil } }),
                                 arrowEdge: .trailing) {
                            ComponentInspector(
                                component: component,
                                livesIn: component.place,
                                uses: component.uses.keys.sorted().map { ($0, component.uses[$0] ?? "") },
                                commit: { fields, rename in board.updateComponent(component.name, fields: fields, rename: rename) },
                                currentRefusal: { board.refusal },
                                close: { inspecting = nil })
                        }
                        .offset(x: CGFloat(at.x), y: CGFloat(at.y))
                        .offset(liveOffset(for: .component(component.name), place: component.place))
                        .gesture(board.tool == .arrow ? AnyGesture(arrowDrag(from: component.name).map { _ in () })
                                                      : AnyGesture(elementDrag(.component(component.name)).map { _ in () }))
                        .onTapGesture {
                            select(.component(component.name))
                            if !NSEvent.modifierFlags.contains(.shift) { inspecting = component.name }
                        }
                }
            }
            ForEach(board.map.notes.filter { note in note.at.map { BoardGeometry.rect(ofNoteAt: $0).intersects(visible) } ?? false }) { note in
                if let at = note.at {
                    Group {
                        if editingNote == note.id {
                            NoteEditor(text: note.text) { text in
                                board.setNoteText(note.id, to: text)
                                editingNote = nil
                            }
                        } else {
                            NoteCard(note: note, isSelected: board.selection.contains(.note(note.id)))
                                .gesture(elementDrag(.note(note.id)))
                                .onTapGesture(count: 2) { editingNote = note.id }
                                .onTapGesture { select(.note(note.id)) }
                                .overlay { glow(.note(note.id), cornerRadius: 10) }
                        }
                    }
                    .offset(x: CGFloat(at.x), y: CGFloat(at.y))
                    .offset(liveOffset(for: .note(note.id), place: nil, rect: BoardGeometry.rect(ofNoteAt: at)))
                }
            }
            ForEach(board.map.texts.filter { BoardGeometry.rect(of: $0).intersects(visible) }) { text in
                Group {
                    if editingText == text.id {
                        LineEditor(text: text.text, font: TextLabel.font(text.style), width: CGFloat(max(text.width, 120))) { words in
                            board.setText(text.id, to: words, width: TextLabel.width(of: words, style: text.style))
                            editingText = nil
                            return true
                        }
                    } else {
                        TextLabel(text: text, isSelected: board.selection.contains(.text(text.id)))
                            .gesture(elementDrag(.text(text.id)))
                            .onTapGesture(count: 2) { editingText = text.id }
                            .onTapGesture { select(.text(text.id)) }
                    }
                }
                .offset(x: CGFloat(text.at.x), y: CGFloat(text.at.y))
                .offset(liveOffset(for: .text(text.id), place: nil, rect: BoardGeometry.rect(of: text)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scaleEffect(viewport.zoom, anchor: .topLeading)
        .offset(x: -viewport.originX * viewport.zoom, y: -viewport.originY * viewport.zoom)
    }

    /// The soft accent outline an outside change leaves on a component or note; nothing when it
    /// isn't glowing.
    @ViewBuilder
    private func glow(_ element: BoardModel.Element, cornerRadius: CGFloat) -> some View {
        if glowing.contains(element) {
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.accent.opacity(glowOpacity), lineWidth: 2)
        }
    }

    /// The same outline for a frame — a view overlay, not a `Canvas` stroke: `Canvas` never
    /// re-invokes its content closure per animation frame just because a plain `@State` it reads
    /// is being animated with `withAnimation`, so a stroke drawn there jumps instead of fading.
    /// A real view, like the component and note glow, participates in SwiftUI's animation system
    /// properly and fades exactly as they do.
    @ViewBuilder
    private func frameGlow(_ frame: BoardFrame) -> some View {
        if glowing.contains(.frame(frame.label)), let rect = frameRect(frame) {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent.opacity(glowOpacity), lineWidth: 2)
                .frame(width: CGFloat(rect.w), height: CGFloat(rect.h))
                .offset(x: CGFloat(rect.x), y: CGFloat(rect.y))
                .offset(liveOffset(for: .frame(frame.label), place: nil))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func frameHandles(_ frame: BoardFrame) -> some View {
        if let rect = frameRect(frame) {
            let offset = liveOffset(for: .frame(frame.label), place: nil)
            Group {
                if editingFrame == frame.label {
                    LineEditor(text: frame.label, font: .system(size: 10, weight: .semibold), width: 160,
                               refusal: frameRenameRefusal) { label in
                        if board.renameFrame(frame.label, to: label) {
                            editingFrame = nil
                            frameRenameRefusal = nil
                            return true
                        }
                        frameRenameRefusal = board.refusal
                        return false
                    }
                } else {
                    FrameLabel(label: frame.label, isSelected: board.selection.contains(.frame(frame.label)))
                        .gesture(elementDrag(.frame(frame.label)))
                        .onTapGesture(count: 2) { editingFrame = frame.label; frameRenameRefusal = nil }
                        .onTapGesture { select(.frame(frame.label)) }
                }
            }
            .offset(x: CGFloat(rect.x + 12), y: CGFloat(rect.y) - 9)
            .offset(offset)
            FrameGrip()
                .offset(x: CGFloat(rect.maxX) - 16, y: CGFloat(rect.maxY) - 16)
                .offset(offset)
                .gesture(resizeDrag(frame.label))
        }
    }

    @ViewBuilder
    private var overlays: some View {
        switch board.state {
        case .failed(let reason):
            BoardNotice(
                title: "This map couldn't be read", detail: reason, tone: Theme.statusError,
                action: ("Try again", { board.reload() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            BoardEmptyState(
                runningCount: board.suggestions.count,
                addRunning: { board.addAllRunning(); fitAll() },
                startEmpty: { board.startMap() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ZStack {
                VStack(spacing: 6) {
                    HStack(alignment: .top) {
                        TextField("What is this project?", text: $systemDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: 360, alignment: .leading)
                            .focused($systemFocused)
                            .onSubmit { board.setSystem(systemDraft) }
                            .onChange(of: systemFocused) { _, focused in
                                if !focused { board.setSystem(systemDraft) }
                            }
                        Spacer()
                        if !board.suggestions.isEmpty {
                            Button { showingSuggestions = true } label: {
                                Text("\(board.suggestions.count) running, not on the map ›")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingSuggestions) {
                                SuggestionList(
                                    suggestions: board.suggestions,
                                    add: { board.addSuggestion($0) },
                                    addAll: { board.addAllRunning(); showingSuggestions = false })
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    if board.changedOnDisk {
                        BoardBanner(text: "system-map.json keeps changing under the Board. Reload takes the file; edits not saved here are dropped.",
                                    tone: Theme.contextWarn, action: ("Reload", { board.reload() }))
                    }
                    if let failure = board.writeFailure {
                        BoardBanner(text: "Couldn't save the map: \(failure)", tone: Theme.contextWarn,
                                    action: ("Retry", { board.saveNow() }))
                    }
                    if let liveUpdatesOff = board.liveUpdatesOff {
                        BoardBanner(text: liveUpdatesOff, tone: Theme.textTertiary)
                    }
                    Spacer()
                    if let refusal = board.refusal {
                        Text(refusal).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    BoardToolbar(board: board, lastKind: $lastKind)
                        .padding(.bottom, 12)
                }
                .padding(.top, 10)

                if let quickAddAt {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(viewport.toScreen(quickAddAt))
                        .popover(isPresented: Binding(get: { self.quickAddAt != nil }, set: { if !$0 { self.quickAddAt = nil } })) {
                            QuickAddMenu { choice in
                                place(choice, at: quickAddAt)
                                self.quickAddAt = nil
                            }
                        }
                }

                if let editingArrow, let points = board.routes[editingArrow], let mid = labelPoint(
                    points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }) {
                    LineEditor(
                        text: board.map.components.first { $0.name == editingArrow.from }?.uses[editingArrow.to] ?? "",
                        font: .system(size: 10), width: 160
                    ) { label in
                        board.setArrowLabel(editingArrow, to: label)
                        self.editingArrow = nil
                        return true
                    }
                    .position(mid)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: board.map.system, initial: true) { _, system in
                if !systemFocused { systemDraft = system ?? "" }
            }
        }
    }

    // MARK: - Drawing

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var spacing = 16.0
        while spacing * viewport.zoom < 12 { spacing *= 2 }
        let visible = viewport.visibleRect(width: Double(size.width), height: Double(size.height))
        let startX = (Double(visible.minX) / spacing).rounded(.down) * spacing
        let startY = (Double(visible.minY) / spacing).rounded(.down) * spacing
        var dots = Path()
        var x = startX
        while x <= Double(visible.maxX) {
            var y = startY
            while y <= Double(visible.maxY) {
                let point = viewport.toScreen(CGPoint(x: x, y: y))
                dots.addEllipse(in: CGRect(x: point.x - 0.8, y: point.y - 0.8, width: 1.6, height: 1.6))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(Theme.boardDot))
    }

    private func drawFrames(in context: inout GraphicsContext) {
        for frame in board.map.frames {
            guard let rect = frameRect(frame) else { continue }
            let offset = liveOffset(for: .frame(frame.label), place: nil)
            let origin = viewport.toScreen(CGPoint(x: Double(rect.x), y: Double(rect.y)))
            let screen = CGRect(x: origin.x + offset.width * viewport.zoom, y: origin.y + offset.height * viewport.zoom,
                                width: Double(rect.w) * viewport.zoom, height: Double(rect.h) * viewport.zoom)
            let path = Path(roundedRect: screen, cornerRadius: 12 * viewport.zoom)
            context.fill(path, with: .color(Theme.boardFrameFill))
            let selected = board.selection.contains(.frame(frame.label))
            context.stroke(path, with: .color(selected ? Theme.accent.opacity(0.7) : Theme.boardFrameStroke), lineWidth: 1)
        }
    }

    private func drawArrows(in context: inout GraphicsContext) {
        for component in board.map.components {
            for (target, label) in component.uses {
                let key = BoardModel.ArrowKey(from: component.name, to: target)
                guard let points = livePoints(for: key) else { continue }
                let screen = points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }
                let selected = board.selection.contains(.arrow(key))
                let planned = board.map.components.first { $0.name == target }?.planned == true
                let colour = selected ? Theme.accent : Theme.boardArrow
                context.stroke(arrowPath(screen), with: .color(colour),
                               style: StrokeStyle(lineWidth: selected ? 1.8 : 1.3, lineCap: .round, lineJoin: .round, dash: planned ? [4, 4] : []))
                if let head = arrowHead(screen) { context.fill(head, with: .color(colour)) }
                if !label.isEmpty, let mid = labelPoint(screen) {
                    let text = context.resolve(Text(label).font(.system(size: 9.5)).foregroundColor(Theme.textSecondary))
                    let measured = text.measure(in: CGSize(width: 240, height: 40))
                    let box = CGRect(x: mid.x - measured.width / 2 - 5, y: mid.y - measured.height / 2 - 2,
                                     width: measured.width + 10, height: measured.height + 4)
                    context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Theme.boardBackground))
                    context.draw(text, at: mid)
                }
            }
        }
    }

    /// A straight arrow draws as a gentle curve leaving and entering along its anchor sides; an
    /// elbow draws through its points with rounded joins.
    private func arrowPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        if points.count == 2 {
            let horizontal = abs(last.x - first.x) >= abs(last.y - first.y)
            let pull = horizontal ? (last.x - first.x) * 0.4 : (last.y - first.y) * 0.4
            let c1 = horizontal ? CGPoint(x: first.x + pull, y: first.y) : CGPoint(x: first.x, y: first.y + pull)
            let c2 = horizontal ? CGPoint(x: last.x - pull, y: last.y) : CGPoint(x: last.x, y: last.y - pull)
            path.addCurve(to: last, control1: c1, control2: c2)
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    /// The head points the way the arrow arrives: along its anchor side for a curve, along the
    /// last segment for an elbow.
    private func arrowHead(_ points: [CGPoint]) -> Path? {
        guard points.count >= 2, let tip = points.last else { return nil }
        let angle: Double
        if points.count == 2 {
            let first = points[0]
            angle = abs(tip.x - first.x) >= abs(tip.y - first.y)
                ? (tip.x >= first.x ? 0 : .pi)
                : (tip.y >= first.y ? .pi / 2 : -.pi / 2)
        } else {
            let from = points[points.count - 2]
            angle = atan2(Double(tip.y - from.y), Double(tip.x - from.x))
        }
        let length = 7.0
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - 0.45), y: tip.y - length * sin(angle - 0.45)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + 0.45), y: tip.y - length * sin(angle + 0.45)))
        path.closeSubpath()
        return path
    }

    private func labelPoint(_ points: [CGPoint]) -> CGPoint? {
        guard points.count >= 2 else { return nil }
        let index = (points.count - 1) / 2
        let a = points[index], b = points[index + 1]
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    // MARK: - Geometry helpers

    private func visibleCanvasRect() -> BoardRect {
        let rect = viewport.visibleRect(width: Double(size.width), height: Double(size.height))
        return BoardRect(x: rect.x - 64, y: rect.y - 64, w: rect.w + 128, h: rect.h + 128)
    }

    private func componentRect(_ component: BoardComponent) -> BoardRect? {
        component.at.map(BoardGeometry.rect(ofComponentAt:))
    }

    private func frameRect(_ frame: BoardFrame) -> BoardRect? {
        if let resizing, resizing.label == frame.label { return resizing.rect }
        return frame.rect
    }

    /// The canvas offset of an element mid-drag: its own, or the frame's it lives in or sits
    /// wholly inside.
    private func liveOffset(for element: BoardModel.Element, place: String?, rect: BoardRect? = nil) -> CGSize {
        guard !dragging.isEmpty else { return .zero }
        let carriedByPlace = place.map { dragging.contains(.frame($0)) } ?? false
        let carriedByFrame = rect.map { rect in
            board.map.frames.contains { frame in
                dragging.contains(.frame(frame.label)) && (frame.rect.map { BoardGeometry.interior(of: $0).contains(rect) } ?? false)
            }
        } ?? false
        guard dragging.contains(element) || carriedByPlace || carriedByFrame else { return .zero }
        return CGSize(width: dragOffset.width / viewport.zoom, height: dragOffset.height / viewport.zoom)
    }

    /// An arrow's points, following its ends live while either is being dragged.
    private func livePoints(for key: BoardModel.ArrowKey) -> [BoardPoint]? {
        guard !dragging.isEmpty else { return board.routes[key] }
        func liveRect(_ name: String) -> BoardRect? {
            guard let component = board.map.components.first(where: { $0.name == name }), let rect = componentRect(component) else { return nil }
            let offset = liveOffset(for: .component(name), place: component.place)
            return rect.offsetBy(dx: Int(offset.width), dy: Int(offset.height))
        }
        guard let from = liveRect(key.from), let to = liveRect(key.to) else { return nil }
        let moved = liveOffset(for: .component(key.from), place: nil) != .zero
            || liveOffset(for: .component(key.to), place: nil) != .zero
            || board.map.components.contains { ($0.name == key.from || $0.name == key.to) && dragging.contains(.frame($0.place)) }
        return moved ? BoardGeometry.route(from: from, to: to, obstacles: []) : board.routes[key]
    }

    // MARK: - Viewport

    private func placeViewport() {
        if let saved = sidebarState.boardViewport(for: projectPath) {
            viewport = saved
        } else if !board.isEmpty {
            fitAll()
        } else {
            viewport = .initial
        }
    }

    private func fitAll() {
        guard let bounds = board.contentBounds else { return }
        viewport = BoardViewport.fitting(bounds, width: Double(size.width), height: Double(size.height))
    }

    private func wireInput() {
        input.canvasFrame = { canvasFrame }
        input.onSpace = { spaceHeld = $0 }
        input.onScroll = { point, dx, dy, precise, command in
            if command {
                let factor = precise ? exp(Double(dy) * 0.01) : (dy > 0 ? 1.1 : 1 / 1.1)
                viewport = viewport.zoomed(by: factor, aroundScreen: point)
            } else {
                let scale = precise ? 1.0 : 8.0
                viewport = viewport.panned(byScreenDX: Double(dx) * scale, dy: Double(dy) * scale)
            }
        }
        input.onMagnify = { point, magnification in
            viewport = viewport.zoomed(by: 1 + Double(magnification), aroundScreen: point)
        }
        input.onKey = { press in
            guard let command = BoardKeyMap.command(for: press, isEditingText: BoardInput.isEditingText) else { return false }
            perform(command)
            return true
        }
    }

    private func perform(_ command: BoardCommand) {
        switch command {
        case .delete: board.delete(board.selection)
        case .cancel:
            board.selection = []
            board.tool = .select
            inspecting = nil
            quickAddAt = nil
            arrowDraft = nil
            frameDraft = nil
        case .undo: board.undo()
        case .redo: board.redo()
        case .fitAll: fitAll()
        case .selectTool: board.tool = .select
        case .componentTool: board.tool = .component(lastKind)
        case .arrowTool: board.tool = .arrow
        case .frameTool: board.tool = .frame
        case .noteTool: board.tool = .note
        case .textTool: board.tool = .text
        }
    }

    // MARK: - Gestures

    private func select(_ element: BoardModel.Element) {
        if NSEvent.modifierFlags.contains(.shift) {
            if board.selection.contains(element) { board.selection.remove(element) } else { board.selection.insert(element) }
        } else {
            board.selection = [element]
        }
    }

    private func elementDrag(_ element: BoardModel.Element) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragging.isEmpty {
                    if !board.selection.contains(element) { board.selection = [element] }
                    dragging = board.selection.filter { if case .arrow = $0 { return false } else { return true } }
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let delta = BoardPoint(x: Int((value.translation.width / viewport.zoom).rounded()),
                                       y: Int((value.translation.height / viewport.zoom).rounded()))
                let moved = dragging
                dragging = []
                dragOffset = .zero
                board.move(moved, by: delta)
            }
    }

    private func resizeDrag(_ label: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let rect = board.map.frames.first(where: { $0.label == label })?.rect else { return }
                resizing = (label, BoardRect(x: rect.x, y: rect.y,
                                             w: rect.w + Int(value.translation.width / viewport.zoom),
                                             h: rect.h + Int(value.translation.height / viewport.zoom)))
            }
            .onEnded { _ in
                if let resizing { board.resizeFrame(resizing.label, to: resizing.rect) }
                resizing = nil
            }
    }

    /// The four side handles on a hovered component; dragging one draws an arrow.
    private func handles(for name: String) -> some View {
        let size = BoardGeometry.componentSize
        let points = [CGPoint(x: size.x / 2, y: 0), CGPoint(x: size.x, y: size.y / 2),
                      CGPoint(x: size.x / 2, y: size.y), CGPoint(x: 0, y: size.y / 2)]
        return ZStack(alignment: .topLeading) {
            ForEach(points.indices, id: \.self) { index in
                Circle()
                    .fill(Theme.boardBackground)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .position(points[index])
                    .gesture(arrowDrag(from: name))
            }
        }
        .frame(width: CGFloat(size.x), height: CGFloat(size.y))
    }

    private func arrowDrag(from name: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in arrowDraft = (name, value.location) }
            .onEnded { value in
                arrowDraft = nil
                let point = viewport.toCanvas(value.location)
                let dropped = BoardPoint(x: Int(point.x), y: Int(point.y))
                if let target = board.map.components.first(where: { componentRect($0)?.contains(dropped) == true }) {
                    board.addArrow(from: name, to: target.name)
                }
                board.tool = .select
            }
    }

    private func backgroundDragChanged(_ value: DragGesture.Value) {
        if spaceHeld || panStart != nil {
            if panStart == nil { panStart = viewport }
            if let panStart {
                viewport = panStart.panned(byScreenDX: Double(value.translation.width), dy: Double(value.translation.height))
            }
            return
        }
        if board.tool == .frame {
            frameDraft = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
            return
        }
        guard board.tool == .select else { return }
        marquee = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                         width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
    }

    private func backgroundDragEnded(_ value: DragGesture.Value) {
        if panStart != nil {
            panStart = nil
            return
        }
        if let frameDraft {
            self.frameDraft = nil
            let topLeft = viewport.toCanvas(frameDraft.origin)
            let bottomRight = viewport.toCanvas(CGPoint(x: frameDraft.maxX, y: frameDraft.maxY))
            editingFrame = board.addFrame(BoardRect(x: Int(topLeft.x), y: Int(topLeft.y),
                                                    w: Int(bottomRight.x - topLeft.x), h: Int(bottomRight.y - topLeft.y)))
            frameRenameRefusal = nil
            board.tool = .select
            return
        }
        guard let marquee else { return }
        self.marquee = nil
        let topLeft = viewport.toCanvas(marquee.origin)
        let bottomRight = viewport.toCanvas(CGPoint(x: marquee.maxX, y: marquee.maxY))
        let area = BoardRect(x: Int(topLeft.x), y: Int(topLeft.y),
                             w: Int(bottomRight.x - topLeft.x), h: Int(bottomRight.y - topLeft.y))
        var picked: Set<BoardModel.Element> = []
        for component in board.map.components where componentRect(component)?.intersects(area) == true {
            picked.insert(.component(component.name))
        }
        for note in board.map.notes where note.at.map({ BoardGeometry.rect(ofNoteAt: $0).intersects(area) }) == true {
            picked.insert(.note(note.id))
        }
        for text in board.map.texts where BoardGeometry.rect(of: text).intersects(area) {
            picked.insert(.text(text.id))
        }
        board.selection = NSEvent.modifierFlags.contains(.shift) ? board.selection.union(picked) : picked
    }

    /// A tap on empty canvas places what the tool makes, or — with Select — selects the arrow
    /// under it, or clears the selection.
    private func backgroundTapped(at location: CGPoint) {
        let point = viewport.toCanvas(location)
        switch board.tool {
        case .component(let kind): place(.component(kind), at: point)
        case .note: place(.note, at: point)
        case .text: place(.text, at: point)
        case .frame: place(.frame, at: point)
        case .arrow: board.selection = []
        case .select:
            if let arrow = arrow(near: location) { select(.arrow(arrow)) } else { board.selection = [] }
        }
    }

    private func backgroundDoubleTapped(at location: CGPoint) {
        guard board.tool == .select else { return }
        if let arrow = arrow(near: location) {
            board.selection = [.arrow(arrow)]
            editingArrow = arrow
        } else {
            quickAddAt = viewport.toCanvas(location)
        }
    }

    /// Places one thing centred on `point` (canvas), opens its editor, and returns to Select.
    private func place(_ choice: QuickAddChoice, at point: CGPoint) {
        let x = Int(point.x), y = Int(point.y)
        switch choice {
        case .component(let kind):
            let size = BoardGeometry.componentSize
            if let name = board.addComponent(kind: kind, at: BoardPoint(x: x - size.x / 2, y: y - size.y / 2)) {
                inspecting = name
            }
        case .note:
            let size = BoardGeometry.noteSize
            editingNote = board.addNote(at: BoardPoint(x: x - size.x / 2, y: y - size.y / 2))
        case .text:
            let width = TextLabel.width(of: "Text", style: .label)
            editingText = board.addText(at: BoardPoint(x: x - width / 2, y: y - 10), style: .label, text: "Text", width: width)
        case .frame:
            editingFrame = board.addFrame(BoardRect(x: x - 160, y: y - 100, w: 320, h: 200))
            frameRenameRefusal = nil
        }
        board.tool = .select
    }

    /// The arrow within 6 screen points of `location`, if any.
    func arrow(near location: CGPoint) -> BoardModel.ArrowKey? {
        for (key, points) in board.routes {
            let screen = points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }
            for (a, b) in zip(screen, screen.dropFirst()) where distance(from: location, toSegment: a, b) < 6 {
                return key
            }
        }
        return nil
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// The Board of a project with no map: start from what is running, or start empty.
struct BoardEmptyState: View {
    let runningCount: Int
    let addRunning: () -> Void
    let startEmpty: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("No map for this project yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(runningCount > 0
                 ? "linkC can see \(runningCount) container\(runningCount == 1 ? "" : "s") running for this project. Start from those, or draw it yourself."
                 : "Draw what this project is made of: its databases, services and hosts, and how they talk.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: 8) {
                if runningCount > 0 {
                    Button("Add what's running (\(runningCount))", action: addRunning)
                        .buttonStyle(.borderedProminent)
                }
                Button("Start empty", action: startEmpty)
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
            Text("Nothing is written until you add something.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary.opacity(0.8))
        }
    }
}

/// A centred notice for a Board that cannot be used as it is.
struct BoardNotice: View {
    let title: String
    let detail: String
    let tone: Color
    let action: (String, () -> Void)

    var body: some View {
        VStack(spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action.0, action: action.1)
                .buttonStyle(.bordered)
        }
    }
}

/// A one-line banner across the top of the canvas.
struct BoardBanner: View {
    let text: String
    let tone: Color
    /// `nil` for a quiet banner with nothing to do about it — the watcher being off, say, where
    /// there is no retry that means anything.
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(tone)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.boardBox))
        .overlay(Capsule().strokeBorder(tone.opacity(0.35), lineWidth: 1))
    }
}
