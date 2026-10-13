import LinkCKit
import SwiftUI

/// What the panel shows where a terminal, or a project's Split grid, lives in its own window. The
/// window keeps the terminal's single live view; this only says so and offers the way to it, or back.
/// `compact` is for a grid cell, where there is little room.
struct WindowedNote: View {
    let model: AppModel
    let item: TornOffItem
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Text("Open in its own window")
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: compact ? 10 : 14) {
                QuietLink("Show window", size: compact ? 10 : 11) { model.raise(item, focusing: nil) }
                QuietLink("Bring back", size: compact ? 10 : 11) { model.bringBack(item) }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
