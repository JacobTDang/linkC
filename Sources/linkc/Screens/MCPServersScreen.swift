import SwiftUI
import AppKit
import LinkCKit

/// Every MCP server claude knows about, with live health. Config renders instantly from
/// `~/.claude.json` (read-only, secrets structurally absent); status chips fill in as
/// `claude mcp list` reports. Global servers get live health; project-scoped ones show
/// static config only (per-project checks are a v1.1 affordance).
struct MCPServersScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let service = model.mcpServers {
                content(service)
            } else {
                Color.clear  // unreachable: services exist whenever setup succeeded
            }
        }
        .task {
            model.mcpServers?.loadConfig()
            await model.mcpServers?.refreshHealth()
        }
    }

    @ViewBuilder private func content(_ service: MCPServerService) -> some View {
        ScreenHeader(title: "MCP Servers", isBusy: service.isRefreshing) {
            ChromeButton(systemName: "arrow.clockwise", help: "Re-check server health") {
                Task { await service.refreshHealth() }
            }
            .disabled(service.isRefreshing)
        }

        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                if !service.servers.isEmpty {
                    SectionHeader(title: "GLOBAL").padding(.top, 4)
                    ForEach(service.servers) { server in
                        MCPServerRow(server: server, status: service.health[server.name])
                    }
                }
                ForEach(projectGroups(service), id: \.path) { group in
                    SectionHeader(title: (group.path as NSString).abbreviatingWithTildeInPath.uppercased())
                        .padding(.top, 6)
                    ForEach(group.servers) { server in
                        MCPServerRow(server: server, status: nil)
                    }
                }
                if !service.connectedAccounts.isEmpty {
                    SectionHeader(title: "CONNECTED ACCOUNTS").padding(.top, 6)
                    ForEach(service.connectedAccounts, id: \.name) { account in
                        MCPAccountRow(account: account)
                    }
                }
                HStack {
                    QuietLink("Reveal config in Finder") {
                        let url = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".claude.json")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 4)
            }
            .readingColumn()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        if let error = service.lastError {
            ErrorBar(message: error)
        }
    }

    private func projectGroups(_ service: MCPServerService) -> [(path: String, servers: [MCPServerConfig])] {
        Dictionary(grouping: service.projectServers) { server -> String in
            if case .project(let path) = server.scope { return path }
            return ""
        }
        .map { (path: $0.key, servers: $0.value.sorted { $0.name < $1.name }) }
        .sorted { $0.path < $1.path }
    }
}

/// One configured server: transport glyph, name, secret-free target, status chip. Hover
/// reveals a copy-target button (copies only the target string — secrets were never parsed).
private struct MCPServerRow: View {
    let server: MCPServerConfig
    let status: MCPHealthStatus?

    @State private var hovering = false

    private var target: String {
        switch server.transport {
        case .http(let url, _): return url
        case .stdio(let command, let args, _): return ([command] + args).joined(separator: " ")
        }
    }

    private var isHTTP: Bool {
        if case .http = server.transport { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isHTTP ? "globe" : "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            Text(server.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(target)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if hovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy target")
                .transition(.opacity)
            }

            if server.isDisabledForProject {
                Text("disabled")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            } else {
                MCPStatusChip(state: status?.state)
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
}

/// A claude.ai managed connector (Gmail/Drive/Calendar) — reported by the CLI, absent from
/// the config file, no actions.
private struct MCPAccountRow: View {
    let account: MCPHealthStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            Text(account.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            MCPStatusChip(state: account.state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// The live-status glyph: teal connected, gold needs-auth, red failed, dim dot when
/// unchecked or unrecognized.
private struct MCPStatusChip: View {
    let state: MCPHealthStatus.State?

    private var label: (text: String, color: Color) {
        switch state {
        case .connected: return ("connected", Theme.statusRunning)
        case .needsAuth: return ("needs auth", Theme.contextWarn)
        case .failed: return ("failed", Theme.statusError)
        case .unknown(let text): return (text.lowercased(), Theme.textTertiary)
        case nil: return ("not checked", Theme.textTertiary)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(label.color).frame(width: 6, height: 6)
            Text(label.text)
                .font(.system(size: 10))
                .foregroundStyle(label.color == Theme.textTertiary ? Theme.textTertiary : Theme.textSecondary)
        }
        .fixedSize()
    }
}
