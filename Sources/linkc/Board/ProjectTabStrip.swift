import AppKit
import SwiftUI
import LinkCKit

/// The Chrome-style strip above the right pane: the project's Board, pinned, then a tab per
/// session, then ＋. ⌘1–⌘9 pick a tab and ⌃Tab cycles, through a local key monitor that exists
/// only while the strip does.
struct ProjectTabStrip: View {
    let model: AppModel
    let onBack: (() -> Void)?

    @State private var confirming: ProjectTab?
    @State private var keys = TabKeys()

    private static let minTab: CGFloat = 96
    private static let maxTab: CGFloat = 180

    var body: some View {
        // A terminal-read action isn't observable, so the strip re-reads once a second while
        // one of its sessions is working, and hourly (effectively never) otherwise — one
        // `TimelineView`, same schedule type either way, so switching the interval never tears
        // down the key monitor or the confirmation dialog below, which stay on this outer view.
        let anyWorking = model.projectHasWorkingSession
        TimelineView(.periodic(from: .now, by: anyWorking ? 1 : 3600)) { _ in
            let tabs = model.projectTabs
            let selected = model.selectedTabID
            HStack(spacing: 4) {
                if let onBack {
                    ChromeButton(systemName: "chevron.left", help: "Back", action: onBack)
                }
                if let board = tabs.first {
                    TabChip(tab: board, isSelected: board.id == selected, width: nil,
                            onSelect: { model.select(board) }, onClose: nil)
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 14)
                GeometryReader { geometry in
                    let sessions = Array(tabs.dropFirst())
                    let width = sessions.isEmpty
                        ? Self.maxTab
                        : min(Self.maxTab, max(Self.minTab, geometry.size.width / CGFloat(sessions.count) - 2))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(sessions) { tab in
                                TabChip(tab: tab, isSelected: tab.id == selected, width: width,
                                        onSelect: { model.select(tab) }, onClose: { requestClose(tab) })
                            }
                        }
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                        .frame(height: geometry.size.height, alignment: .bottom)
                        .background(WindowDragHandle())
                    }
                    .scrollDisabled(CGFloat(sessions.count) * (width + 2) <= geometry.size.width)
                }
                .frame(height: 30)
                Menu {
                    ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                        Button("Add \(kind.displayName)") {
                            if let project = model.currentProject { model.spawnTeammate(in: project, agent: kind) }
                        }
                    }
                } label: {
                    RowGlyph(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add an agent to this project")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .background(WindowDragHandle().ignoresSafeArea(edges: .top))
        .background(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .background(WindowReader { keys.window = $0 })
        .onAppear {
            keys.onCommand = handle
            keys.start()
        }
        .onDisappear { keys.stop() }
        .confirmationDialog(
            "Stop \(confirming?.title ?? "this session")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { tab in
            Button("Stop", role: .destructive) { model.close(tab) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's in the middle of a turn.")
        }
    }

    /// A session mid-turn asks first; an idle one closes at once.
    private func requestClose(_ tab: ProjectTab) {
        if tab.isWorking {
            confirming = tab
        } else {
            model.close(tab)
        }
    }

    private func handle(_ command: TabCommand) {
        let tabs = model.projectTabs
        switch command {
        case .select(let digit):
            if let tab = ProjectTabs.tab(forDigit: digit, in: tabs) { model.select(tab) }
        case .next, .previous:
            if let tab = ProjectTabs.cycle(from: model.selectedTabID, in: tabs, backwards: command == .previous) {
                model.select(tab)
            }
        }
    }
}

/// One tab.
private struct TabChip: View {
    let tab: ProjectTab
    let isSelected: Bool
    let width: CGFloat?
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            switch tab.kind {
            case .board:
                Image(systemName: "square.grid.2x2").font(.system(size: 10))
            case .agent(let kind):
                AgentLogoView(agent: kind)
            case .terminal:
                Image(systemName: "terminal").font(.system(size: 9))
            }
            if let activity = tab.activity {
                ActivityLabel(text: activity.text, isWorking: activity.isWorking, size: 11.5)
            } else {
                Text(tab.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let onClose {
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Stop this session")
            }
        }
        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(width: width, height: 28, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.08) : (hovering ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

/// ⌘1–⌘9 and ⌃Tab, through a local key monitor installed only while the strip is showing.
@MainActor
final class TabKeys {
    var onCommand: (TabCommand) -> Void = { _ in }
    /// The window the strip itself lives in, from `WindowReader` — not just any key window, so
    /// a popover or the open panel being briefly key never steals these keys.
    var window: NSWindow?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, !BoardInput.isEditingText,
                  let press = BoardInput.press(from: event),
                  let command = TabKeyMap.command(for: press) else { return event }
            self.onCommand(command)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
