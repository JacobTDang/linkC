import SwiftUI
import LinkCKit

/// The services your tools depend on — one card per compose project (the firecrawl stack as
/// a unit, not seven anonymous containers), standalone containers below. Light management
/// through the docker CLI; logs open as dev terminals.
struct ToolServersScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let service = model.toolServers {
                content(service)
            } else {
                Color.clear  // unreachable: services exist whenever setup succeeded
            }
        }
        .task { await model.toolServers?.refresh() }
    }

    @ViewBuilder private func content(_ service: ToolServerService) -> some View {
        HStack(spacing: 8) {
            Text("Tool Servers")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if service.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Spacer()
            ChromeButton(systemName: "arrow.clockwise", help: "Refresh containers") {
                Task { await service.refresh() }
            }
            .disabled(service.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)

        if service.projects.isEmpty && service.standalone.isEmpty && service.lastError == nil {
            VStack(spacing: 6) {
                Text("Nothing running")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Compose stacks and containers show up here once docker has them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(service.projects) { project in
                        ProjectHeader(project: project, service: service)
                            .padding(.top, 6)
                        ForEach(project.containers) { container in
                            ContainerRow(container: container, service: service, model: model)
                        }
                    }
                    if !service.standalone.isEmpty {
                        SectionHeader(title: "STANDALONE").padding(.top, 6)
                        ForEach(service.standalone) { container in
                            ContainerRow(container: container, service: service, model: model)
                        }
                    }
                }
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
                ChromeGlyphButton(systemName: "stop.circle", help: "Stop stack") {
                    Task { await service.projectAction(.stop, name: project.name) }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// One container: service name, ports, state chip; hover reveals logs / restart /
/// start-or-stop, disabled while any action on it is in flight.
private struct ContainerRow: View {
    let container: ContainerInfo
    let service: ToolServerService
    let model: AppModel

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
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
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
