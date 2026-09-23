import SwiftUI

/// A session's current action — its icon, the text, and a shimmer while it works. The header,
/// the tab strip and the sidebar rows all draw it this way.
struct ActivityLabel: View {
    let text: String
    let isWorking: Bool
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: activityIcon(for: text))
                .font(.system(size: size - 2))
                .foregroundStyle(isWorking ? Theme.accent : Theme.textTertiary)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .smoothShimmer(isWorking: isWorking)
        }
    }
}
