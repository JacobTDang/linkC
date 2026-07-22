import SwiftUI
import LinkCKit

/// The Settings screen — placeholder until preferences land.
struct SettingsScreen: View {
    let model: AppModel

    var body: some View {
        ScreenPlaceholder(title: "Settings")
    }
}

/// Shared placeholder body while screens are being built out.
struct ScreenPlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Coming together…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
