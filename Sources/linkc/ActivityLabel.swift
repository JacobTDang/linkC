import SwiftUI

/// A session's current action — its icon, the text, and a shimmer while it works. The header,
/// the tab strip and the sidebar rows all draw it this way. Sets no text colour of its own — it
/// inherits from the surrounding view, so a tab chip's selected/unselected style still applies;
/// the icon keeps its accent-when-working colour regardless.
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
                .lineLimit(1)
                .truncationMode(.tail)
                .smoothShimmer(isWorking: isWorking)
        }
    }
}
