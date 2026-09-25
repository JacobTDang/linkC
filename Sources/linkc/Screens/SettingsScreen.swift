import SwiftUI
import LinkCKit

/// linkC's own settings — the app's open threads made real: launch at login (system-truth via
/// SMAppService, read fresh on every appearance), a preset global shortcut, and panel
/// behavior. Claude's config is deliberately not here; the other two screens cover it.
struct SettingsScreen: View {
    let model: AppModel

    @State private var launchAtLogin = false
    @State private var loginItemBusy = false
    @State private var errorText: String?
    /// A decode error from a folder's own `.linkc/app.json`, surfaced once under the row
    /// `addApp()` just appended — keyed by folder so the right row seeds its error text from it
    /// the moment it's created.
    @State private var addedWithDecodeError: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Settings") { EmptyView() }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    SectionHeader(title: "GENERAL").padding(.top, 4)
                    SettingRow(
                        title: "Launch at login",
                        detail: "Start linkC when you log in to your Mac."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(loginItemBusy)
                    }

                    SectionHeader(title: "SHORTCUT").padding(.top, 6)
                    SettingRow(
                        title: "Toggle panel",
                        detail: "A global shortcut that opens and closes the panel from anywhere."
                    ) {
                        Picker("", selection: Binding(
                            get: { model.preferences.hotKeyPreset },
                            set: { model.preferences.hotKeyPreset = $0 }
                        )) {
                            ForEach(AppPreferences.HotKeyPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }

                    SectionHeader(title: "MODELS").padding(.top, 6)
                    ForEach([AgentKind.claude, .codex, .agy], id: \.self) { agent in
                        SettingRow(
                            title: agent.displayName,
                            detail: "Which model each tier launches. A renamed model can be typed in."
                        ) {
                            HStack(spacing: 6) {
                                ForEach(ModelTier.resolutionOrder, id: \.self) { tier in
                                    TierModelField(preferences: model.preferences, agent: agent, tier: tier)
                                }
                                Picker("", selection: Binding(
                                    get: { model.preferences.agentModels.defaultTier(for: agent) },
                                    set: { newValue in
                                        var edited = model.preferences.agentModels
                                        edited.setDefaultTier(newValue, for: agent)
                                        model.preferences.agentModels = edited
                                    }
                                )) {
                                    ForEach(ModelTier.resolutionOrder, id: \.self) { tier in
                                        Text(tier.label).tag(tier)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }

                    SectionHeader(title: "APPS").padding(.top, 6)
                    Text(
                        "Apps listed here can open in every project, from the + menu. "
                            + "A project can also ship its own `.linkc/app.json`."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    ForEach(model.preferences.linkCApps) { setting in
                        AppSettingRow(
                            preferences: model.preferences,
                            folder: setting.folder,
                            manifest: setting.manifest,
                            initialError: addedWithDecodeError[setting.folder],
                            onCommitted: { addedWithDecodeError[setting.folder] = nil },
                            onRemove: {
                                model.preferences.linkCApps.removeAll { $0.folder == setting.folder }
                                addedWithDecodeError[setting.folder] = nil
                            }
                        )
                    }
                    HStack {
                        QuietLink("Add app…") { addApp() }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                    SectionHeader(title: "PANEL").padding(.top, 6)
                    SettingRow(
                        title: "Show plan usage",
                        detail: "The 5h / 7d token footer under the session list."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { model.preferences.showsUsageFooter },
                            set: { model.preferences.showsUsageFooter = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }

                    SectionHeader(title: "WATCHED SERVICES").padding(.top, 6)
                    SettingRow(
                        title: "Health checks",
                        detail: "Supabase projects are checked automatically. Add anything "
                            + "else — a web app behind a domain — to endpoints.json as "
                            + #"[{"label": "…", "url": "https://…"}]."#
                    ) {
                        QuietLink("reveal", size: 11) {
                            if let path = model.revealEndpointsConfig() {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: path)]
                                )
                            }
                        }
                    }
                }
                .readingColumn()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let errorText {
                ErrorBar(message: errorText)
            }

            // What am I running? Version from the release tag, build from the git commit —
            // stamped by build-app.sh, so a stale install is identifiable at a glance.
            HStack {
                Text("linkC \(Self.versionLabel)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemBusy = true
        launchAtLogin = enabled  // reflect intent immediately; reverted below on failure
        Task {
            defer { loginItemBusy = false }
            do {
                try await LoginItem.setEnabled(enabled)
                errorText = nil
            } catch {
                errorText = "Couldn't update Login Items: \(error.localizedDescription)"
            }
            launchAtLogin = LoginItem.isEnabled  // system truth, whatever happened
        }
    }

    /// Add app…: pick a folder, prefill from its own `.linkc/app.json` when it has one and it
    /// decodes, prefill with defaults otherwise (showing the decode error under the new row when
    /// the file exists but is broken), then register the app for every project.
    private func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app's folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let folder = (url.path as NSString).standardizingPath
        guard !model.preferences.linkCApps.contains(where: { ($0.folder as NSString).standardizingPath == folder }) else {
            errorText = "Already registered."
            return
        }
        let manifestURL = url.appendingPathComponent(LinkCAppManifest.relativePath)
        let defaultManifest = LinkCAppManifest(name: url.lastPathComponent, start: [], health: "/", path: "/")
        var manifest = defaultManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                manifest = try LinkCAppManifest.decode(Data(contentsOf: manifestURL))
            } catch {
                addedWithDecodeError[folder] = error.localizedDescription
            }
        }
        model.preferences.linkCApps.append(LinkCAppSetting(folder: folder, manifest: manifest))
    }
}

/// One settings row: title + explanatory detail on the left, the control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// One model-id text field. Holds the typed text locally and commits it to preferences only
/// on submit or on losing focus — never per keystroke, so a half-typed id (e.g. mid-edit
/// "gpt-6-ast") is never briefly the live mapping a relay tick could launch a session with.
private struct TierModelField: View {
    let preferences: AppPreferences
    let agent: AgentKind
    let tier: ModelTier

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(tier.label, text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.mini)
            .frame(width: 96)
            .focused($isFocused)
            .onAppear { text = currentValue }
            .onSubmit { commit() }
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if wasFocused && !nowFocused { commit() }
            }
    }

    private var currentValue: String {
        preferences.agentModels.model(for: agent, tier: tier) ?? ""
    }

    private func commit() {
        guard text != currentValue else { return }
        var edited = preferences.agentModels
        edited.setModel(text, for: agent, tier: tier)
        preferences.agentModels = edited
    }
}

/// One Settings app editor: the folder (read-only, middle-truncated), its four manifest fields,
/// a Remove button, and a red error line when the last commit was rejected. `folder` is the
/// setting's stable identity — `manifest` and `initialError` only seed the row's local state the
/// first time it appears; after that, every edit reads and writes `preferences.linkCApps` fresh,
/// by folder, so a sibling row's commit never clobbers this one.
private struct AppSettingRow: View {
    let preferences: AppPreferences
    let folder: String
    let onCommitted: () -> Void
    let onRemove: () -> Void

    @State private var nameText: String
    @State private var startText: String
    @State private var healthText: String
    @State private var pathText: String
    @State private var errorText: String?

    init(
        preferences: AppPreferences,
        folder: String,
        manifest: LinkCAppManifest,
        initialError: String?,
        onCommitted: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.folder = folder
        self.onCommitted = onCommitted
        self.onRemove = onRemove
        _nameText = State(initialValue: manifest.name)
        _startText = State(initialValue: CommandLineSplit.join(manifest.start))
        _healthText = State(initialValue: manifest.health)
        _pathText = State(initialValue: manifest.path)
        _errorText = State(initialValue: initialError)
    }

    /// The manifest as currently stored — read fresh, never the value captured at `init`, so a
    /// commit always builds on top of whatever the store actually holds.
    private var storedManifest: LinkCAppManifest? {
        preferences.linkCApps.first { $0.folder == folder }?.manifest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                QuietLink("Remove", size: 11, action: onRemove)
            }
            HStack(spacing: 6) {
                CommitField(placeholder: "Name", text: $nameText, width: 90, onCommit: commit)
                CommitField(placeholder: "Start command", text: $startText, width: 170, onCommit: commit)
                CommitField(placeholder: "Health path", text: $healthText, width: 80, onCommit: commit)
                CommitField(placeholder: "Page path", text: $pathText, width: 80, onCommit: commit)
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func commit() {
        do {
            let start = try CommandLineSplit.split(startText)
            let candidate = try LinkCAppManifest(
                name: nameText,
                start: start,
                health: healthText,
                path: pathText,
                env: storedManifest?.env ?? [:]
            ).validated()
            var apps = preferences.linkCApps
            guard let index = apps.firstIndex(where: { $0.folder == folder }) else { return }
            apps[index] = LinkCAppSetting(folder: folder, manifest: candidate)
            preferences.linkCApps = apps
            errorText = nil
            onCommitted()
        } catch let error as LinkCError {
            errorText = error.localizedDescription
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// One editable field inside an `AppSettingRow`. Commits on submit and on losing focus — never
/// per keystroke — the same pattern as `TierModelField`, generalized to an external binding so
/// several fields can share one row's commit.
private struct CommitField: View {
    let placeholder: String
    @Binding var text: String
    let width: CGFloat
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.mini)
            .frame(width: width)
            .focused($isFocused)
            .onSubmit(onCommit)
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if wasFocused && !nowFocused { onCommit() }
            }
    }
}
