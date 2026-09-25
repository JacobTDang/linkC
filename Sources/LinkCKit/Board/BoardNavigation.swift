import Foundation

/// One board of one project: the overview (slug nil) or a detail board.
public struct BoardAddress: Hashable, Sendable {
    public let projectPath: String   // standardized
    public let slug: String?

    public init(projectPath: String, slug: String?) {
        self.projectPath = (projectPath as NSString).standardizingPath
        self.slug = slug
    }

    /// Where this board's viewport and lens are kept: the project path for the overview, so
    /// existing saved viewports still apply; "<path>#<slug>" for a detail board.
    public var viewportKey: String {
        if let slug {
            return "\(projectPath)#\(slug)"
        }
        return projectPath
    }

    /// The board one level up: "a.b" → "a", "a" → the overview, the overview → nil.
    public var up: BoardAddress? {
        guard let slug else { return nil }
        if let lastDot = slug.lastIndex(of: ".") {
            return BoardAddress(projectPath: projectPath, slug: String(slug[..<lastDot]))
        }
        return BoardAddress(projectPath: projectPath, slug: nil)
    }
}

public enum BoardNavigation {
    public struct Crumb: Equatable, Sendable {
        public let title: String
        public let address: BoardAddress

        public init(title: String, address: BoardAddress) {
            self.title = title
            self.address = address
        }
    }

    /// The breadcrumb for `address`:
    /// - a linked board gives one crumb per level, pairing `entry.path` with the slug's
    ///   prefixes;
    /// - an unlinked board gives the overview, then the slug;
    /// - a slug the catalog doesn't know gives the overview alone.
    public static func crumbs(for address: BoardAddress, in catalog: BoardCatalog) -> [Crumb] {
        let overviewTitle = catalog.entries.first(where: { $0.slug == nil })?.path.first
            ?? URL(fileURLWithPath: address.projectPath).lastPathComponent
        let overviewCrumb = Crumb(title: overviewTitle, address: BoardAddress(projectPath: address.projectPath, slug: nil))

        guard let slug = address.slug else {
            return [overviewCrumb]
        }

        guard let entry = catalog.entry(for: slug) else {
            return [overviewCrumb]
        }

        if !entry.linked {
            return [
                overviewCrumb,
                Crumb(title: slug, address: address)
            ]
        }

        var result = [overviewCrumb]
        let segments = slug.split(separator: ".")
        for i in 1..<entry.path.count {
            let crumbSlug = segments.prefix(i).joined(separator: ".")
            result.append(Crumb(title: entry.path[i], address: BoardAddress(projectPath: address.projectPath, slug: crumbSlug)))
        }
        return result
    }

    public struct MenuRow: Equatable, Sendable {
        public let title: String
        public let indent: Int
        public let address: BoardAddress?   // nil for the "Unlinked" header row

        public init(title: String, indent: Int, address: BoardAddress?) {
            self.title = title
            self.indent = indent
            self.address = address
        }
    }

    /// The Boards ▾ menu:
    /// - every linked entry in catalog order, titled by its last path element and indented by
    ///   its depth;
    /// - then, when any exist, an "Unlinked" header row (address nil, indent 0) followed by
    ///   each unlinked entry, titled by its slug and indented by 1.
    public static func menuRows(for catalog: BoardCatalog, projectPath: String) -> [MenuRow] {
        let standardizedPath = (projectPath as NSString).standardizingPath
        var rows: [MenuRow] = []

        let linkedEntries = catalog.entries.filter(\.linked)
        for entry in linkedEntries {
            let title = entry.path.last ?? (entry.slug ?? "")
            rows.append(MenuRow(title: title, indent: entry.depth, address: BoardAddress(projectPath: standardizedPath, slug: entry.slug)))
        }

        let unlinkedEntries = catalog.entries.filter { !$0.linked }
        if !unlinkedEntries.isEmpty {
            rows.append(MenuRow(title: "Unlinked", indent: 0, address: nil))
            for entry in unlinkedEntries {
                let title = entry.slug ?? ""
                rows.append(MenuRow(title: title, indent: 1, address: BoardAddress(projectPath: standardizedPath, slug: entry.slug)))
            }
        }

        return rows
    }
}
