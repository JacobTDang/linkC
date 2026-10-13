import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LinkCKit

/// The Chrome-style strip above the right pane: the project's Board, pinned, then its Split when it
/// has one showing, then a tab per session, then ＋. ⌘1–⌘9 pick a tab and ⌃Tab cycles, through a
/// local key monitor that exists only while the strip does.
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
                                        windowActions: windowActions(for: tab),
                                        onSelect: { model.select(tab) }, onClose: { requestClose(tab) })
                            }
                        }
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                        .frame(height: geometry.size.height, alignment: .bottom)
                        .background(WindowDragHandle())
                    }
                    .scrollDisabled(CGFloat(sessions.count) * (width + 2) <= geometry.size.width)
                    // A split pane dragged by its title row and dropped here leaves the split. Anything
                    // else, a member's own tab chip included, is declined, so a drag that means
                    // nothing here is left to whatever else would take it.
                    .dropDestination(for: LinkCTerminalDrag.self) { items, _ in
                        guard let project = model.splitProject, let drag = items.first, drag.fromPane,
                              model.liveSplitMembers(in: project).contains(drag.id) else { return false }
                        model.removeFromSplit(drag.id, in: project)
                        return true
                    }
                }
                .frame(height: 30)
                Menu {
                    ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                        Button("Add \(kind.displayName)") {
                            if let project = model.currentProject { model.spawnTeammate(in: project, agent: kind) }
                        }
                    }
                    Divider()
                    Button("New terminal") {
                        if let project = model.currentProject { model.newTerminal(in: project) }
                    }
                    if let project = model.currentProject {
                        AppsMenuSection(model: model, project: project)
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

    /// What a chip can open in its own window: a session or terminal, or the project's Split. nil for
    /// the Board and apps, which have no window of their own. The closures run later, from AppKit.
    private func windowActions(for tab: ProjectTab) -> TabChip.WindowActions? {
        let item: TornOffItem
        switch tab.kind {
        case .agent, .terminal:
            item = .terminal(tab.id)
        case .split:
            guard let project = model.currentProject else { return nil }
            item = .split(ProjectTabs.standardized(project))
        case .board, .app:
            return nil
        }
        return TabChip.WindowActions(
            isTornOff: model.tornOff.contains(item),
            tearOff: { [weak model] point in model?.tearOff(item, at: point) },
            bringBack: { [weak model] in model?.bringBack(item) })
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

/// The Apps section shared by the strip's + menu and the sidebar's project + menu: one item per
/// app the project can open, each starting it; a manifest that doesn't validate shows its reason
/// disabled, rather than hiding the app. Nothing shows when the project has no apps.
@MainActor @ViewBuilder
func AppsMenuSection(model: AppModel, project: String) -> some View {
    let apps = model.apps(in: project)
    if !apps.isEmpty {
        Divider()
        Section("Apps") {
            ForEach(apps) { entry in
                switch entry.manifest {
                case .success:
                    Button(entry.name) { model.openApp(entry, in: project) }
                case .failure(let error):
                    Button("\(entry.name) — \(error.localizedDescription)") {}.disabled(true)
                }
            }
        }
    }
}

/// One tab. A session, terminal or Split chip is also an AppKit drag source (`DragOutSource`) that
/// opens in a window when dragged out of the panel; the Board and apps just select.
private struct TabChip: View {
    /// What a chip does with its own window.
    struct WindowActions {
        let isTornOff: Bool
        /// Opens the window: centred on the point (screen coordinates), or beside the panel for nil.
        let tearOff: (CGPoint?) -> Void
        let bringBack: () -> Void

        /// The chip's menu item, and the same action for VoiceOver.
        var toggleTitle: LocalizedStringKey { isTornOff ? "Bring back" : "Open in Window" }

        func toggle() {
            if isTornOff { bringBack() } else { tearOff(nil) }
        }
    }

    let tab: ProjectTab
    let isSelected: Bool
    let width: CGFloat?
    var windowActions: WindowActions?
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var hovering = false

    /// The type of a Split chip's drag. Nothing accepts it, so only dragging out does anything.
    private static let splitTabType = NSPasteboard.PasteboardType("com.linkc.split-tab")

    var body: some View {
        interactive
            .onHover { hovering = $0 }
            .help(tab.title)
    }

    @ViewBuilder
    private var interactive: some View {
        if let windowActions {
            // The source sits behind the chip: the label doesn't hit-test, so a press on it reaches the
            // source, and the × above stays a button.
            content(labelHitTests: false, windowActions: windowActions)
                .background {
                    DragOutSource(payload: dragPayload, onClick: onSelect,
                                  onDraggedOut: { windowActions.tearOff($0) }, toolTip: tab.title)
                }
                .background(fill.allowsHitTesting(false))
                .contextMenu {
                    Button(windowActions.toggleTitle, action: windowActions.toggle)
                }
                // The press is an AppKit view VoiceOver can't act on, so the chip says what it does.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, onSelect)
                .accessibilityAction(named: windowActions.toggleTitle, windowActions.toggle)
        } else {
            content(labelHitTests: true, windowActions: nil)
                .background(fill)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
        }
    }

    private func content(labelHitTests: Bool, windowActions: WindowActions?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                switch tab.kind {
                case .board:
                    Image(systemName: "square.grid.2x2").font(.system(size: 10))
                case .agent(let kind):
                    AgentLogoView(agent: kind)
                case .terminal:
                    Image(systemName: "terminal").font(.system(size: 9))
                case .app:
                    Image(systemName: "globe").font(.system(size: 9))
                case .split:
                    Image(systemName: "square.split.2x2").font(.system(size: 10))
                }
                if let activity = tab.activity {
                    ActivityLabel(text: activity.text, isWorking: activity.isWorking, size: 11.5)
                } else {
                    Text(tab.title)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if windowActions?.isTornOff == true {
                    Image(systemName: "macwindow")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .allowsHitTesting(labelHitTests)
            if let onClose {
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(hovering || isSelected ? 1 : 0)
                .help(tab.kind == .split ? "Close the split" : "Stop this session")
            }
        }
        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(width: width, height: 28, alignment: .leading)
    }

    private var fill: some View {
        UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
            .fill(isSelected ? Color.white.opacity(0.08) : (hovering ? Theme.hover : .clear))
    }

    /// A session or terminal chip carries what the panel's split edges, the strip and the sidebar
    /// accept, so it can also be dropped on a terminal's edge to split with it.
    private var dragPayload: NSPasteboardItem {
        let item = NSPasteboardItem()
        switch tab.kind {
        case .agent, .terminal:
            do {
                let data = try JSONEncoder().encode(LinkCTerminalDrag(id: tab.id))
                item.setData(data, forType: NSPasteboard.PasteboardType(UTType.linkcTerminal.identifier))
            } catch {
                preconditionFailure("A terminal drag always encodes: \(error)")
            }
        case .split:
            item.setString(tab.id, forType: Self.splitTabType)
        case .board, .app:
            preconditionFailure("Only a session, terminal or Split chip drags.")
        }
        return item
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
