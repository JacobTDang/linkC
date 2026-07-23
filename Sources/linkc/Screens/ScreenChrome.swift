import SwiftUI
import LinkCKit

/// One header for every rail screen — same title treatment, same busy indicator, same
/// action placement, so the five screens read as one surface.
struct ScreenHeader<Actions: View>: View {
    let title: String
    var isBusy: Bool = false
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// One empty-state pattern for every screen: what this place is, and the one thing to do.
struct EmptyHint: View {
    let title: String
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if let actionLabel, let action {
                QuietLink(actionLabel, action: action)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Content stops stretching at a reading width — at large panel sizes rows keep card
    /// proportions and the glass breathes beside them instead of thinning every row.
    func readingColumn() -> some View {
        frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
