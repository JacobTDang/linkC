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
    @State private var addingDiscordProject: String?
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
                    // The refresher is observable: this view redraws when a refresh ends, and never reads
                    // the cache file itself.
                    let refresher = model.coordinator?.modelListRefresher
                    if refresher?.isRefreshing == true {
                        Text("Refreshing the model lists…")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 4)
                    }
                    if let cacheProblem = refresher?.cacheProblem {
                        Text(cacheProblem)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.statusError)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                    ForEach([AgentKind.claude, .codex, .agy, .grok, .opencode], id: \.self) { agent in
                        let lists = refresher?.lists ?? [:]
                        let choices = TierModelChoices.make(
                            agent: agent, lists: lists, settings: model.preferences.agentModels,
                            current: model.preferences.agentModels.model(for: agent, tier: .standard) ?? "")
                        VStack(alignment: .leading, spacing: 4) {
                            SettingRow(
                                title: agent.displayName,
                                detail: "Which model each tier launches. Pick one, or Other… to type an id."
                            ) {
                                HStack(spacing: 6) {
                                    ForEach(ModelTier.resolutionOrder, id: \.self) { tier in
                                        TierModelField(
                                            preferences: model.preferences, agent: agent, tier: tier,
                                            lists: lists)
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
                            if choices.listAgeText != nil || choices.listError != nil {
                                HStack(spacing: 6) {
                                    if let age = choices.listAgeText {
                                        Text("Listed \(age)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    if let error = choices.listError {
                                        Text(error)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.statusError)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    if let modelsSaveRefusal = model.preferences.modelsSaveRefusal {
                        Text(modelsSaveRefusal)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.contextWarn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
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

                    SectionHeader(title: "DISCORD").padding(.top, 6)
                    Text(
                        "linkC posts its events to Discord: an agent finishing or needing you, tasks, closed "
                            + "workers, rate limits and watched services. A project with its own webhook posts "
                            + "there, its subfolders and worktrees too; everything else goes to the default. "
                            + "Webhook URLs stay in your Keychain. "
                            + "Name each webhook \u{201C}linkC\u{201D} in Discord: its posts show that name."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    if let discord = model.discord {
                        DiscordWebhookRow(discord: discord, account: DiscordWebhooks.defaultAccount, title: "Default")
                        ForEach(discord.webhooks.projects, id: \.self) { folder in
                            DiscordWebhookRow(discord: discord, account: folder,
                                              title: (folder as NSString).lastPathComponent)
                        }
                        if let folder = addingDiscordProject, !discord.webhooks.projects.contains(folder) {
                            DiscordWebhookRow(discord: discord, account: folder,
                                              title: (folder as NSString).lastPathComponent,
                                              opensEditing: true, onDone: { addingDiscordProject = nil })
                                .id(folder)
                        }
                        HStack {
                            QuietLink("Add project…") { addDiscordProject() }
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
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
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            if let refresher = model.coordinator?.modelListRefresher {
                Task { await refresher.refreshNow() }
            }
        }
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

    private func addDiscordProject() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder whose events go to a webhook of their own"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = ProjectPath.canonical(url.path)
        if model.discord?.webhooks.projects.contains(folder) == true {
            errorText = "This project already has a webhook."
        } else {
            errorText = nil
            addingDiscordProject = folder
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

/// One Discord webhook in Settings: its name, its webhook's id (never the URL) and status, and
/// set / test / remove. The URL is typed into a secure field and cleared once stored.
private struct DiscordWebhookRow: View {
    let discord: DiscordNotifier<ContinuousClock>
    let account: String
    let title: String
    /// Opens with the field showing: a project just added has no webhook yet.
    var opensEditing = false
    var onDone: () -> Void = {}

    @State private var editing = false
    @State private var text = ""
    @State private var error: String?

    private var state: DiscordWebhookState { discord.webhooks.state(for: account) }

    private var isSet: Bool {
        if case .set = state { return true }
        return false
    }

    private var detail: String {
        switch state {
        case .notSet: "Not set"
        case .set(let webhook): "Webhook \(webhook.id) · \(discord.status(for: account).label(now: Date()))"
        case .missing: WebhookStatus.missing.label(now: Date())
        case .unreadable(let reason): reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if isSet { QuietLink("test") { run { try discord.sendTest(to: account) } } }
                QuietLink(isSet ? "change" : "set") { editing.toggle() }
                if state != .notSet || account != DiscordWebhooks.defaultAccount {
                    QuietLink("remove") {
                        run {
                            try discord.remove(account)
                            onDone()
                        }
                    }
                }
            }
            if editing {
                HStack(spacing: 6) {
                    SecureField("https://discord.com/api/webhooks/…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.mini)
                        .onSubmit { save() }
                    QuietLink("save") { save() }
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.contextWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { if opensEditing { editing = true } }
    }

    private func save() {
        run {
            try discord.set(text, for: account)
            text = ""
            editing = false
            onDone()
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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

/// One tier's model picker: listed ids, plus "Other…" which reveals a text field for a typed id.
/// Typed text commits on submit or blur — never per keystroke — so a half-typed id is never the
/// live mapping a relay tick could launch with. OpenCode refuses a non-free typed id.
private struct TierModelField: View {
    let preferences: AppPreferences
    let agent: AgentKind
    let tier: ModelTier
    let lists: [AgentKind: AgentModelList]

    @State private var text: String = ""
    @State private var pickingOther = false
    @FocusState private var isFocused: Bool

    private var choices: TierModelChoices {
        TierModelChoices.make(
            agent: agent, lists: lists, settings: preferences.agentModels, current: currentValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(tier.label, selection: Binding(
                get: { pickingOther ? TierModelChoices.otherLabel : choices.selectedOption },
                set: { select($0) }
            )) {
                ForEach(choices.optionLabels, id: \.self) { label in
                    Text(label).tag(label)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 120, alignment: .leading)

            if pickingOther || choices.showsOtherField {
                TextField(tier.label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .frame(width: 120)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { wasFocused, nowFocused in
                        if wasFocused && !nowFocused { commit() }
                    }
                if let error = TierModelChoices.validationError(forTypedId: text, agent: agent) {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.statusError)
                        .frame(width: 120, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            text = currentValue
            pickingOther = choices.showsOtherField
        }
    }

    private var currentValue: String {
        preferences.agentModels.model(for: agent, tier: tier) ?? ""
    }

    private func select(_ label: String) {
        if label == TierModelChoices.otherLabel {
            pickingOther = true
            return
        }
        pickingOther = false
        text = label
        commit(force: label)
    }

    private func commit(force value: String? = nil) {
        let next = (value ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        // A non-free OpenCode id is not written; the refusal stays under the field, with the typed text.
        guard TierModelChoices.validationError(forTypedId: next, agent: agent) == nil else { return }
        guard next != currentValue else { return }
        var edited = preferences.agentModels
        edited.setModel(next, for: agent, tier: tier)
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
                env: storedManifest?.env ?? [:],
                port: storedManifest?.port
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
