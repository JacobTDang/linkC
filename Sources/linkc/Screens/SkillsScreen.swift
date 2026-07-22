import SwiftUI
import LinkCKit

/// The Skills screen — placeholder until the skills service lands.
struct SkillsScreen: View {
    let model: AppModel

    var body: some View {
        ScreenPlaceholder(title: "Skills")
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
