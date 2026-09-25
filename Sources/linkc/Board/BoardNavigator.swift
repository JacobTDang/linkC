import SwiftUI
import LinkCKit

/// The breadcrumb and Boards ▾ menu at the top-left of a Board.
struct BoardNavigator: View {
    let address: BoardAddress
    let catalog: BoardCatalog?
    let onNavigate: (BoardAddress) -> Void

    var body: some View {
        HStack(spacing: 8) {
            breadcrumb
            if let catalog {
                boardsMenu(catalog)
            }
        }
    }

    private var crumbs: [BoardNavigation.Crumb] {
        if let catalog {
            return BoardNavigation.crumbs(for: address, in: catalog)
        }
        let title = address.slug ?? URL(fileURLWithPath: address.projectPath).lastPathComponent
        return [BoardNavigation.Crumb(title: title, address: address)]
    }

    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: 5) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("›")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
                if index < crumbs.count - 1 {
                    Button {
                        onNavigate(crumb.address)
                    } label: {
                        Text(crumb.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(crumb.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private func boardsMenu(_ catalog: BoardCatalog) -> some View {
        let rows = BoardNavigation.menuRows(for: catalog, projectPath: address.projectPath)
        Menu {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let target = row.address {
                    Button {
                        onNavigate(target)
                    } label: {
                        let indentSpaces = String(repeating: "    ", count: row.indent)
                        let check = (target == address) ? "✓ " : ""
                        Text("\(check)\(indentSpaces)\(row.title)")
                    }
                } else {
                    Button(row.title) {}
                        .disabled(true)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Boards")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
