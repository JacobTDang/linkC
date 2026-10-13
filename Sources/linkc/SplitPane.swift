import LinkCKit
import SwiftUI

/// A project's Split tab: its live split members in an even grid (see `SplitLayout`), each a full
/// live terminal. A click inside a pane, or on its title row, gives it the keyboard and the focus
/// outline; the title row's × takes it out of the split (its session keeps running).
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

    var body: some View {
        // Titles and dots read inputs that are not observable (inbox files, terminal screens). They
        // are resolved here, where the signal is read, and handed to the cells as values: a cell's
        // own inputs do not change when the signal publishes, so it would skip its body.
        let _ = model.sidebarSignal.signal
        let state = model.splitPaneState(in: project)
        let panes = state.members.map {
            SplitPaneItem(id: $0, title: model.splitPaneTitle($0, titles: state.titles), dot: model.splitPaneDot($0),
                          host: model.host(of: $0))
        }
        let focused = state.focused
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
                // Rows are keyed by position, not by their first member, so a row that widens keeps
                // its cells; a cell is rebuilt only when its member moves to another row.
                VStack(spacing: 6) {
                    ForEach(Array(SplitLayout.rowRanges(for: panes.count).enumerated()), id: \.offset) { _, range in
                        HStack(spacing: 6) {
                            ForEach(panes[range]) { pane in
                                SplitCell(model: model, project: project, grid: host, pane: pane, isFocused: pane.id == focused)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// What a pane shows beside its terminal, resolved once per render by `SplitPane`.
private struct SplitPaneItem: Identifiable {
    let id: String
    let title: String
    let dot: ProjectDot?
    /// The window that holds this terminal's live view, nil for the panel.
    let host: TornOffItem?
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
        let hostedHere = pane.host == grid
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
            .onTapGesture { model.clickSplitPane(id, in: project) }
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
                    if !hostedHere, let elsewhere = pane.host {
                        WindowedNote(model: model, item: elsewhere, compact: true)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                        .stroke(Theme.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                        .animation(Theme.hoverEase, value: isFocused)
                        .allowsHitTesting(false)
                }
                .terminalDropTarget(model: model, target: id, project: project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .onChange(of: session.map(ObjectIdentifier.init), initial: true) { _, _ in
            TerminalStyle.apply(to: session)
        }
    }
}
