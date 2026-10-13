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
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullBody: some View {
        VStack(spacing: 8) {
            Text("Open in its own window")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 14) {
                QuietLink("Show window", size: 11) { model.raise(item, focusing: nil) }
                QuietLink("Bring back", size: 11) { model.bringBack(item) }
            }
            .lineLimit(1)
        }
    }

    private var compactBody: some View {
        ViewThatFits(in: .horizontal) {
            // Full layout: heading and both links on one line.
            HStack(spacing: 8) {
                Text("In window")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                QuietLink("Show", size: 10) { model.raise(item, focusing: nil) }
                QuietLink("Bring back", size: 10) { model.bringBack(item) }
            }
            .lineLimit(1)

            // Links stacked vertically under a shorter heading.
            VStack(spacing: 4) {
                Text("In window")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                QuietLink("Show", size: 10) { model.raise(item, focusing: nil) }
                QuietLink("Bring back", size: 10) { model.bringBack(item) }
            }
            .lineLimit(1)

            // Narrowest: only the two links.
            VStack(spacing: 4) {
                QuietLink("Show", size: 10) { model.raise(item, focusing: nil) }
                QuietLink("Bring back", size: 10) { model.bringBack(item) }
            }
            .lineLimit(1)
        }
    }
}
