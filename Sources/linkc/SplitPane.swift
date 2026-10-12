import LinkCKit
import SwiftUI

/// A project's Split tab: its live split members in an even grid (see `SplitLayout`), each a full
/// live terminal. A click inside a pane gives it the keyboard and the focus outline; the title row's
/// × takes it out of the split (its session keeps running).
///
/// A pane that ends leaves the tab up to a second before the model's repair ends the grid, so fewer
/// than two live members still render: one fills the pane, none shows a placeholder.
struct SplitPane: View {
    let model: AppModel
    let project: String

    var body: some View {
        // Titles and dots read inputs that are not observable (inbox files, terminal screens). They
        // are resolved here, where the signal is read, and handed to the cells as values: a cell's
        // own inputs do not change when the signal publishes, so it would skip its body.
        let _ = model.sidebarSignal.signal
        let panes = model.liveSplitMembers(in: project).map {
            SplitPaneItem(id: $0, title: model.splitPaneTitle($0), dot: model.splitPaneDot($0))
        }
        let focused = model.focusedSplitMember(in: project)
        Group {
            switch panes.count {
            case 0:
                Text("Select a session")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 1:
                SplitCell(model: model, pane: panes[0], isFocused: true)
            default:
                // Rows are keyed by position, not by their first member, so a row that widens keeps
                // its cells; a cell is rebuilt only when its member moves to another row.
                VStack(spacing: 6) {
                    ForEach(Array(SplitLayout.rowRanges(for: panes.count).enumerated()), id: \.offset) { _, range in
                        HStack(spacing: 6) {
                            ForEach(panes[range]) { pane in
                                SplitCell(model: model, pane: pane, isFocused: pane.id == focused)
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
}

private struct SplitCell: View {
    let model: AppModel
    let pane: SplitPaneItem
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        let id = pane.id
        let session = model.terminalSession(id)
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
                Button { model.removeFromSplit(id) } label: { RowGlyph(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .animation(Theme.hoverEase, value: hovering)
                    .help("Take out of the split (keeps it running)")
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .draggable(LinkCTerminalDrag(id: id, fromPane: true))
            // The click reports from inside AppKit's first-responder change, which can run during a
            // view update: hand it to the main actor instead of writing state from there. The weak
            // model breaks the cycle model -> terminals -> session -> view -> this closure.
            TerminalContainer(session: session, takesFocus: isFocused,
                              onFocus: { [weak model] in Task { @MainActor in model?.focusInSplit(id) } })
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                        .stroke(Theme.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                        .animation(Theme.hoverEase, value: isFocused)
                        .allowsHitTesting(false)
                }
                .terminalDropTarget(model: model, target: id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .onChange(of: session.map(ObjectIdentifier.init), initial: true) { _, _ in
            TerminalStyle.apply(to: session)
        }
    }
}
