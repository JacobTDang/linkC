import SwiftUI
import AppKit
import LinkCKit

/// Every skill claude can reach — user skills and plugin skills in one usage-sorted list.
/// The one write action is per-plugin enable/disable, through the `claude` CLI with a
/// re-read of authoritative state; user skills are always on.
struct SkillsScreen: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A skill opened for reading — clicking a row drills into its SKILL.md.
    @State private var openSkill: SkillEntry?

    var body: some View {
        ZStack {
            if let openSkill {
                SkillDetailView(skill: openSkill) { self.openSkill = nil }
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
            } else {
                VStack(spacing: 0) {
                    if let service = model.skills {
                        content(service)
                    } else {
                        Color.clear  // unreachable: services exist whenever setup succeeded
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.viewSwap, value: openSkill?.id)
        .task { await model.skills?.refresh() }
    }

    @ViewBuilder private func content(_ service: SkillsService) -> some View {
        ScreenHeader(title: "Skills", isBusy: service.isLoading) {
            ChromeButton(systemName: "arrow.clockwise", help: "Reload skills") {
                Task { await service.refresh() }
            }
            .disabled(service.isLoading)
        }

        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                let userSkills = service.skills.filter { $0.source == .user }
                if !userSkills.isEmpty {
                    SectionHeader(title: "YOUR SKILLS").padding(.top, 4)
                    ForEach(userSkills) { skill in
                        SkillRow(skill: skill) { openSkill = skill }
                    }
                }
                ForEach(pluginGroups(service), id: \.plugin.id) { group in
                    PluginHeader(plugin: group.plugin, service: service)
                        .padding(.top, 6)
                    ForEach(group.skills) { skill in
                        SkillRow(skill: skill) { openSkill = skill }
                    }
                }
            }
            .readingColumn()
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
/// The whole row opens the skill's SKILL.md for reading.
private struct SkillRow: View {
    let skill: SkillEntry
    let onOpen: () -> Void

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
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
        .help("Read \(skill.name)")
    }
}

/// A skill opened for reading: its description as the lede, then the SKILL.md body,
/// monospaced and selectable. The file is read fresh on every open — skills change on disk.
private struct SkillDetailView: View {
    let skill: SkillEntry
    let onBack: () -> Void

    @State private var body_: String?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ChromeButton(systemName: "chevron.left", help: "Back to skills", action: onBack)
                Text(skill.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                ChromeButton(systemName: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)])
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let body_ {
                        Text(body_)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.9))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let loadError {
                        Text(loadError)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.statusError)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .onAppear(perform: load)
        .id(skill.id)  // a different skill re-reads
    }

    private func load() {
        let file = URL(fileURLWithPath: skill.path).appendingPathComponent("SKILL.md")
        do {
            body_ = SkillFrontmatterParser.body(try String(contentsOf: file, encoding: .utf8))
            loadError = nil
        } catch {
            body_ = nil
            loadError = "Couldn't read \(file.path): \(error.localizedDescription)"
        }
    }
}
