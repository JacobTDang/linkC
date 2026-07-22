import SwiftUI
import AppKit
import LinkCKit

/// Every skill claude can reach — user skills and plugin skills in one usage-sorted list.
/// The one write action is per-plugin enable/disable, through the `claude` CLI with a
/// re-read of authoritative state; user skills are always on.
struct SkillsScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let service = model.skills {
                content(service)
            } else {
                Color.clear  // unreachable: services exist whenever setup succeeded
            }
        }
        .task { await model.skills?.refresh() }
    }

    @ViewBuilder private func content(_ service: SkillsService) -> some View {
        HStack(spacing: 8) {
            Text("Skills")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if service.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Spacer()
            ChromeButton(systemName: "arrow.clockwise", help: "Reload skills") {
                Task { await service.refresh() }
            }
            .disabled(service.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                let userSkills = service.skills.filter { $0.source == .user }
                if !userSkills.isEmpty {
                    SectionHeader(title: "YOUR SKILLS").padding(.top, 4)
                    ForEach(userSkills) { SkillRow(skill: $0) }
                }
                ForEach(pluginGroups(service), id: \.plugin.id) { group in
                    PluginHeader(plugin: group.plugin, service: service)
                        .padding(.top, 6)
                    ForEach(group.skills) { SkillRow(skill: $0) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        if let error = service.lastError {
            ErrorBar(message: error)
        }
    }

    /// Plugin groups in catalog order (most-used skill first decides group position).
    private func pluginGroups(_ service: SkillsService) -> [(plugin: InstalledPlugin, skills: [SkillEntry])] {
        var groups: [(plugin: InstalledPlugin, skills: [SkillEntry])] = []
        for skill in service.skills {
            guard case .plugin(let plugin) = skill.source else { continue }
            if let index = groups.firstIndex(where: { $0.plugin.id == plugin.id && $0.plugin.scope == plugin.scope }) {
                groups[index].skills.append(skill)
            } else {
                groups.append((plugin: plugin, skills: [skill]))
            }
        }
        return groups
    }
}

/// A plugin's section header: identity on the left, its one management control — the
/// enable/disable toggle — on the right. Disabled while its CLI call is in flight.
private struct PluginHeader: View {
    let plugin: InstalledPlugin
    let service: SkillsService

    var body: some View {
        HStack(spacing: 6) {
            Text(plugin.id.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("v\(plugin.version) · \(plugin.scope)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            Spacer()
            Toggle("", isOn: Binding(
                get: { plugin.enabled },
                set: { enabled in
                    Task { try? await service.setPluginEnabled(plugin, enabled: enabled) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(service.togglingPluginId == plugin.id)
            .help(plugin.enabled ? "Disable this plugin for new sessions" : "Enable this plugin")
        }
        .padding(.horizontal, 4)
    }
}

/// One skill: name, truncated description, usage figures, hover-revealed Reveal in Finder.
private struct SkillRow: View {
    let skill: SkillEntry

    @State private var hovering = false

    private var usageLabel: String? {
        guard skill.usageCount > 0 else { return nil }
        var label = "×\(skill.usageCount)"
        if let last = skill.lastUsedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            label += " · " + formatter.localizedString(for: last, relativeTo: Date())
        }
        return label
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(skill.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(skill.description)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if hovering {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .transition(.opacity)
            }

            if let usageLabel {
                Text(usageLabel)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
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
}
