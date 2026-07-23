import SwiftUI
import AppKit
import LinkCKit

/// The services your tools depend on — one card per compose project (the firecrawl stack as
/// a unit, not seven anonymous containers), standalone containers below. Light management
/// through the docker CLI; logs open as dev terminals.
struct ToolServersScreen: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A container opened for drill-in — inspect overview, stats, log tail.
    @State private var openContainer: ContainerInfo?

    /// "Add stack…": pick the project's folder; the service validates its compose file and
    /// derives the canonical name via `compose config`. Failures land in the screen's error
    /// strip like every other docker complaint.
    private func addStack(_ service: ToolServerService) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Stack"
        panel.message = "Choose a folder containing a compose file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await service.addStack(directory: url.path) }
    }

    var body: some View {
        ZStack {
            if let openContainer, let service = model.toolServers {
                ContainerDetailView(container: openContainer, service: service, model: model) {
                    self.openContainer = nil
                }
                .transition(reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            } else {
                VStack(spacing: 0) {
                    if let service = model.toolServers {
                        content(service)
                    } else {
                        Color.clear  // unreachable: services exist whenever setup succeeded
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.viewSwap, value: openContainer?.id)
        .task { await model.toolServers?.refresh() }
    }

    @ViewBuilder private func content(_ service: ToolServerService) -> some View {
        ScreenHeader(title: "Tool Servers", isBusy: service.isRefreshing) {
            ChromeButton(systemName: "folder.badge.plus", help: "Add a compose stack from its folder") {
                addStack(service)
            }
            ChromeButton(systemName: "arrow.clockwise", help: "Refresh containers") {
                Task { await service.refresh() }
            }
            .disabled(service.isRefreshing)
        }

        // Cold stacks count as content: a folder-added stack must show even when docker
        // has nothing running.
        if service.projects.isEmpty && service.standalone.isEmpty
            && service.coldStacks.isEmpty && service.lastError == nil {
            EmptyHint(
                title: "Nothing running",
                message: "Compose stacks and containers show up here once docker has them — or add one from its folder with the button above."
            )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(service.projects) { project in
                        ProjectHeader(project: project, service: service)
                            .padding(.top, 6)
                        ForEach(project.containers) { container in
                            ContainerRow(container: container, service: service, model: model) {
                                openContainer = container
                            }
                        }
                    }
                    ForEach(service.coldStacks) { stack in
                        ColdStackRow(stack: stack, service: service)
                            .padding(.top, 6)
                    }
                    if !service.standalone.isEmpty {
                        SectionHeader(title: "STANDALONE").padding(.top, 6)
                        ForEach(service.standalone) { container in
                            ContainerRow(container: container, service: service, model: model) {
                                openContainer = container
                            }
                        }
                    }
                    if !service.images.isEmpty {
                        ImagesSection(service: service).padding(.top, 6)
                    }
                }
                .readingColumn()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }

        if let error = service.lastError {
            ErrorBar(message: error)
        }
    }
}

/// A compose project's header: identity + aggregate state left, stack-level actions right.
private struct ProjectHeader: View {
    let project: ToolServerProject
    let service: ToolServerService

    private var isBusy: Bool { service.busyTarget == project.name }

    var body: some View {
        HStack(spacing: 6) {
            Text(project.name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            if let dir = project.workingDir {
                Text((dir as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(project.runningCount)/\(project.containers.count) running")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(project.runningCount == project.containers.count
                    ? Theme.statusRunning : Theme.textTertiary)
                .fixedSize()
            if isBusy {
                ProgressView().controlSize(.mini)
            } else {
                ChromeGlyphButton(systemName: "arrow.clockwise", help: "Restart stack") {
                    Task { await service.projectAction(.restart, name: project.name) }
                }
                ChromeGlyphButton(systemName: "stop.circle", help: "Stop stack (keeps containers)") {
                    Task { await service.projectAction(.stop, name: project.name) }
                }
                ChromeGlyphButton(systemName: "arrow.down.circle", help: "Down — removes the stack's containers") {
                    Task { await service.projectDown(name: project.name) }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A remembered stack with no live containers — dim, with the one action that matters.
private struct ColdStackRow: View {
    let stack: KnownStack
    let service: ToolServerService

    private var isBusy: Bool { service.busyTarget == stack.name }

    var body: some View {
        HStack(spacing: 6) {
            Text(stack.name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Text((stack.workingDir as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            // What the stack contains, for folder-added projects that have never run.
            if !stack.services.isEmpty {
                Text(stack.services.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("down")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            Spacer()
            if isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await service.stackUp(stack) }
                } label: {
                    Text("Up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("docker compose up -d in \(stack.workingDir)")
            }
        }
        .padding(.horizontal, 4)
        .opacity(0.75)
    }
}

/// Local images with pull-per-row and the one housekeeping action — prune of DANGLING
/// images only, behind a confirmation. Volumes are untouchable from this screen by design.
private struct ImagesSection: View {
    let service: ToolServerService

    @State private var confirmingPrune = false

    private var danglingCount: Int { service.images.count { $0.isDangling } }

    var body: some View {
        HStack(spacing: 6) {
            SectionHeader(title: "IMAGES")
            Spacer()
            if danglingCount > 0 {
                Button { confirmingPrune = true } label: {
                    Text("Prune \(danglingCount) dangling")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(service.busyTarget != nil)
                .confirmationDialog(
                    "Remove \(danglingCount) dangling image\(danglingCount == 1 ? "" : "s")?",
                    isPresented: $confirmingPrune
                ) {
                    Button("Prune dangling images", role: .destructive) {
                        Task { await service.pruneDanglingImages() }
                    }
                } message: {
                    Text("Deletes untagged image layers only — rebuildable disk space. Containers and volumes are untouched.")
                }
            }
        }
        ForEach(service.images) { image in
            ImageRow(image: image, service: service)
        }
    }
}

private struct ImageRow: View {
    let image: ImageInfo
    let service: ToolServerService

    @State private var hovering = false

    private var isBusy: Bool { service.busyTarget == image.reference }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            Text(image.isDangling ? "\(image.id.prefix(12)) (dangling)" : image.reference)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(image.isDangling ? Theme.textTertiary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.mini)
            } else if hovering, !image.isDangling {
                ChromeGlyphButton(systemName: "arrow.down.to.line", help: "Pull latest") {
                    Task { await service.pullImage(image.reference) }
                }
            }
            Text("\(image.size) · \(image.createdSince)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.hover : Color.clear)
        )
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// The container drill-in: inspect overview (env keys only — values never parsed), a
/// one-shot stats line, a static log tail, and the two terminal actions. Loaded fresh on
/// every open; each part degrades independently.
private struct ContainerDetailView: View {
    let container: ContainerInfo
    let service: ToolServerService
    let model: AppModel
    let onBack: () -> Void

    @State private var bundle: ToolServerService.DetailBundle?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ChromeButton(systemName: "chevron.left", help: "Back to tool servers", action: onBack)
                Text(container.composeService ?? container.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                ChromeButton(systemName: "text.alignleft", help: "Follow logs in a terminal") {
                    model.openContainerLogs(container)
                }
                ChromeButton(systemName: "terminal", help: "Shell into the container") {
                    model.openContainerExec(container)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let overview = bundle?.overview {
                        DetailGrid(overview: overview, stats: bundle?.stats)
                    }
                    if let logTail = bundle?.logTail {
                        SectionHeader(title: "RECENT LOGS")
                        Text(logTail.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !isLoading, bundle?.overview == nil, bundle?.logTail == nil {
                        Text("Couldn't inspect \(container.name) — is the docker daemon up?")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.statusError)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task(id: container.id) {
            isLoading = true
            bundle = await service.loadDetail(id: container.id)
            isLoading = false
        }
    }
}

/// The overview facts, one quiet labeled line each.
private struct DetailGrid: View {
    let overview: ContainerDetail
    let stats: ContainerStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("image", overview.image)
            fact("state", overview.status + (overview.restartCount > 0 ? " · \(overview.restartCount) restarts" : ""))
            if let started = overview.startedAt {
                fact("started", started.formatted(.relative(presentation: .named)))
            }
            if let stats {
                fact("cpu · mem", "\(stats.cpu) · \(stats.memory)")
            }
            ForEach(overview.ports, id: \.self) { fact("port", $0) }
            ForEach(overview.mounts, id: \.self) { fact("mount", $0) }
            if !overview.envKeys.isEmpty {
                fact("env", overview.envKeys.joined(separator: ", "))
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One container: service name, ports, state chip; hover reveals logs / restart /
/// start-or-stop, disabled while any action on it is in flight.
private struct ContainerRow: View {
    let container: ContainerInfo
    let service: ToolServerService
    let model: AppModel
    let onOpen: () -> Void

    @State private var hovering = false

    private var isBusy: Bool { service.busyTarget == container.id }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .frame(width: 16)
            Text(container.composeService ?? container.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(container.ports.isEmpty ? container.image : container.ports)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.mini)
            } else if hovering {
                ChromeGlyphButton(systemName: "text.alignleft", help: "View logs in a terminal") {
                    model.openContainerLogs(container)
                }
                ChromeGlyphButton(systemName: "terminal", help: "Shell into container") {
                    model.openContainerExec(container)
                }
                ChromeGlyphButton(systemName: "arrow.clockwise", help: "Restart") {
                    Task { await service.containerAction(.restart, id: container.id) }
                }
                if container.state == .running {
                    ChromeGlyphButton(systemName: "stop.circle", help: "Stop") {
                        Task { await service.containerAction(.stop, id: container.id) }
                    }
                } else {
                    ChromeGlyphButton(systemName: "play.circle", help: "Start") {
                        Task { await service.containerAction(.start, id: container.id) }
                    }
                }
            } else {
                Text(stateLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor == Theme.textTertiary ? Theme.textTertiary : Theme.textSecondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
        .help("Inspect \(container.composeService ?? container.name)")
    }

    private var stateColor: Color {
        if container.health == "unhealthy" { return Theme.statusError }
        switch container.state {
        case .running: return Theme.statusRunning
        case .exited: return Theme.textTertiary
        case .other: return Theme.contextWarn
        }
    }

    private var stateLabel: String {
        if container.health == "unhealthy" { return "unhealthy" }
        switch container.state {
        case .running: return container.health == "healthy" ? "healthy" : "running"
        case .exited: return "stopped"
        case .other: return "…"
        }
    }
}

/// A bare small glyph action for dense rows — smaller than the header's ChromeButton.
private struct ChromeGlyphButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
