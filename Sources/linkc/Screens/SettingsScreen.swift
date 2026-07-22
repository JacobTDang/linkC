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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let errorText {
                ErrorBar(message: errorText)
            }
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
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
        .padding(.vertical, 8)
    }
}
