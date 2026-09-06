import SwiftUI
import LinkCKit

/// Amber alert banner displayed on cards when concurrent agents claim overlapping files.
struct CollisionBanner: View {
    let collisions: [CollisionWarning]

    var body: some View {
        if let first = collisions.first {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.contextWarn)

                Text("Collision: '\(first.conflictingFiles.first ?? "file")' also claimed by \(first.conflictingAgent.displayName)")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.contextWarn.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.contextWarn.opacity(0.3), lineWidth: 0.5)
            )
        }
    }
}
