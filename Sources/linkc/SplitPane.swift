import AppKit
import LinkCKit
import SwiftUI

/// A project's Split tab: its live split members in a grid (see `SplitLayout`), each a full live
/// terminal. A click inside a pane, or on its title row, gives it the keyboard and the focus outline;
/// the title row's × takes it out of the split (its session keeps running).
///
/// The gaps between panes are handles. Dragging one resizes the panes either side of it, or the two
/// rows; a double-click evens them out again. The split keeps its sizes until a terminal joins or leaves
/// it, and sizes made for another number of panes show an even grid (`ProjectSplit.gridSizes`).
///
/// A pane that ends leaves the tab up to a second before the model's repair ends the grid, so fewer
/// than two live members still render: one fills the pane, none shows a placeholder.
///
/// `host` is the torn-off window this grid is drawn in, nil for the panel. A terminal's live view
/// lives in one host only, so a pane whose terminal is hosted elsewhere (its own window, or another
/// window's grid) shows a note in place of the terminal and never takes the view.
struct SplitPane: View {
    let model: AppModel
    let project: String
    let host: TornOffItem?
    /// The sizes a handle drag is making: shown live, and stored in the split once, when the drag ends.
    @State private var dragged: SplitSizes?
    /// The sizes the drag started from. Each step applies the drag's whole translation to these, so the
    /// boundary stays under the pointer.
    @State private var dragStart: SplitSizes?

    /// The space between two panes, and between the rows. Each one is a resize handle.
    fileprivate static let gap: CGFloat = 6
    /// The grid's coordinate space: drags are measured in it, so a handle moving under the pointer
    /// doesn't move the ruler.
    private static let space = "splitGrid"

    var body: some View {
        // Titles and dots read inputs that are not observable (inbox files, terminal screens). They
        // are resolved here, where the signal is read, and handed to the cells as values: a cell's
        // own inputs do not change when the signal publishes, so it would skip its body.
        let _ = model.sidebarSignal.signal
        let state = model.splitPaneState(in: project)
        let hosts = model.hosts(of: state.members)
        let panes = state.members.map {
            SplitPaneItem(id: $0, title: model.splitPaneTitle($0, titles: state.titles), dot: model.splitPaneDot($0),
                          hostedIn: hosts[$0])
        }
        let focused = state.focused
        // A drag that outlived its grid (a pane ended mid-drag) fits no grid on screen and is not shown.
        let live = dragged.flatMap { $0.fits(paneCount: panes.count) ? $0 : nil }
        Group {
            switch panes.count {
            case 0:
                Text("Select a session")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 1:
                SplitCell(model: model, project: project, grid: host, pane: panes[0], isFocused: true)
            default:
                grid(panes, focused: focused, sizes: live ?? state.sizes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// The panes in their rows, each pane and row as large as `sizes` makes it, with a handle in every gap.
    /// Rows are keyed by position, not by their first member, so a row that widens keeps its cells; a
    /// cell is rebuilt only when its member moves to another row.
    private func grid(_ panes: [SplitPaneItem], focused: String?, sizes: SplitSizes) -> some View {
        GeometryReader { proxy in
            let ranges = SplitLayout.rowRanges(for: panes.count)
            let gridHeight = SplitSizes.paneSpace(Double(proxy.size.height), count: ranges.count, gap: Double(Self.gap))
            VStack(spacing: 0) {
                ForEach(Array(ranges.enumerated()), id: \.offset) { row, range in
                    if row > 0 {
                        ResizeHandle(axis: .vertical, space: Self.space,
                                     onDrag: { distance in
                                         dragStep(from: sizes) { $0.resizingRows(by: distance, gridHeight: gridHeight) }
                                     },
                                     onEnd: endDrag,
                                     onDoubleClick: { model.resizeSplit(sizes.evenedRows(), in: project) })
                    }
                    let rowWidth = SplitSizes.paneSpace(Double(proxy.size.width), count: range.count, gap: Double(Self.gap))
                    HStack(spacing: 0) {
                        ForEach(Array(panes[range].enumerated()), id: \.element.id) { column, pane in
                            if column > 0 {
                                ResizeHandle(axis: .horizontal, space: Self.space,
                                             onDrag: { distance in
                                                 dragStep(from: sizes) {
                                                     $0.resizingColumns(inRow: row, divider: column - 1, by: distance, rowWidth: rowWidth)
                                                 }
                                             },
                                             onEnd: endDrag,
                                             onDoubleClick: { model.resizeSplit(sizes.evenedRow(row), in: project) })
                            }
                            SplitCell(model: model, project: project, grid: host, pane: pane, isFocused: pane.id == focused)
                                .frame(width: CGFloat(sizes.columns[row][column] * rowWidth))
                        }
                    }
                    .frame(height: CGFloat(sizes.rows[row] * gridHeight))
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    /// One step of a handle drag: `resize` applied to the sizes the drag started from (`shown` on its first step).
    private func dragStep(from shown: SplitSizes, _ resize: (SplitSizes) -> SplitSizes) {
        let start = dragStart ?? shown
        dragStart = start
        dragged = resize(start)
    }

    /// The drag ended: the split keeps the sizes it made, written once rather than on every step.
    private func endDrag() {
        if let made = dragged { model.resizeSplit(made, in: project) }
        dragged = nil
        dragStart = nil
    }
}

/// What a pane shows beside its terminal, resolved once per render by `SplitPane`.
private struct SplitPaneItem: Identifiable {
    let id: String
    let title: String
    let dot: ProjectDot?
    /// The window that holds this terminal's live view, nil for the panel.
    let hostedIn: TornOffItem?
}

private struct SplitCell: View {
    let model: AppModel
    let project: String
    /// The window this cell's grid is drawn in, nil for the panel.
    let grid: TornOffItem?
    let pane: SplitPaneItem
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        let id = pane.id
        // Only the grid that is the terminal's host takes its view; any other shows where it lives.
        let hostedHere = pane.hostedIn == grid
        let session = hostedHere ? model.terminalSession(id) : nil
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(pane.title)
                    .font(.system(size: 11))
                    .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let dot = pane.dot {
                    StateDotView(dot: dot)
                }
                Button { model.removeFromSplit(id, in: project) } label: { RowGlyph(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .animation(Theme.hoverEase, value: hovering)
                    .help("Take out of the split (keeps it running)")
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture { model.clickSplitPane(id, in: project, grid: grid) }
            .draggable(LinkCTerminalDrag(id: id, fromPane: true))
            // Focus reports from inside AppKit's first-responder change, which can run during a
            // view update: hand it to the main actor instead of writing state from there. The weak
            // model breaks the cycle model -> terminals -> session -> view -> these closures. Any pane
            // that takes the keyboard reports focus, one that took it by itself included, so that only
            // moves the selection; a click is the user's pick and opens the pane as a tab would.
            TerminalContainer(session: session, takesFocus: isFocused,
                              onFocus: { [weak model] in Task { @MainActor in model?.focusInSplit(id, in: project) } },
                              onClick: { [weak model] in Task { @MainActor in model?.pickSplitPane(id, in: project) } })
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                .overlay {
                    // A window grid's pane hosted by the panel (nil) shows nothing: that only happens once
                    // the split has fewer than two live panes, and the next prune closes this window.
                    if !hostedHere, let elsewhere = pane.hostedIn {
                        WindowedNote(model: model, item: elsewhere, compact: true)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                        .stroke(Theme.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                        .animation(Theme.hoverEase, value: isFocused)
                        .allowsHitTesting(false)
                }
                // The target stays on a note cell on purpose: a drop only rearranges the grid.
                .terminalDropTarget(model: model, target: id, project: project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .onChange(of: session.map(ObjectIdentifier.init), initial: true) { _, _ in
            TerminalStyle.apply(to: session)
        }
    }
}

/// A gap between panes that resizes them. Dragged, it reports its translation along `axis` in the
/// grid's coordinate space `space`; double-clicked, it asks for the even sizes back. The pointer shows the
/// resize cursor over it and for the whole drag, even once the pointer has run ahead of a boundary that
/// stopped at a minimum.
private struct ResizeHandle: View {
    /// `.horizontal` sits between two panes of a row and moves left and right; `.vertical` sits between
    /// the rows and moves up and down.
    let axis: Axis
    let space: String
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    /// Whether this handle pushed the resize cursor, so it pops only its own.
    @State private var pushedCursor = false

    var body: some View {
        Color.clear
            .frame(width: axis == .horizontal ? SplitPane.gap : nil, height: axis == .vertical ? SplitPane.gap : nil)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                    .onChanged { value in
                        dragging = true
                        onDrag(Double(axis == .horizontal ? value.translation.width : value.translation.height))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    })
            .onTapGesture(count: 2, perform: onDoubleClick)
            .onChange(of: hovering || dragging) { _, wanted in showCursor(wanted) }
            .onDisappear { showCursor(false) }
    }

    private func showCursor(_ show: Bool) {
        guard show != pushedCursor else { return }
        if show {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
        pushedCursor = show
    }
}
