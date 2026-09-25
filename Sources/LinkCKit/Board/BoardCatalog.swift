import Foundation

/// Every board of a project: the overview, then each linked detail board under its parent, in
/// name order, then the detail files nothing links to.
public struct BoardCatalog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// nil is the overview.
        public let slug: String?
        /// The breadcrumb: the project's name, then each part name down to this board.
        public let path: [String]
        public let linked: Bool
        public var depth: Int { path.count - 1 }

        public init(slug: String?, path: [String], linked: Bool) {
            self.slug = slug
            self.path = path
            self.linked = linked
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func entry(for slug: String) -> Entry? { entries.first { $0.slug == slug } }

    /// Reads the project folder: which detail files exist, and which parts link to them.
    public static func load(workspacePath: String, projectName: String) throws -> BoardCatalog {
        let folder = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let files = Set(names.compactMap(BoardSlug.slug(fromFileName:)))
        var entries = [Entry(slug: nil, path: [projectName], linked: true)]
        var reached: Set<String> = []

        func visit(board slug: String?, path: [String]) throws {
            guard let map = try BoardMapStore(workspacePath: workspacePath, board: slug).load()?.map else { return }
            let children = map.components
                .compactMap { part -> (String, String)? in part.detail.map { (part.name, $0) } }
                .filter { files.contains($0.1) && !reached.contains($0.1) }
                .sorted { $0.0.lowercased() < $1.0.lowercased() }
            for (name, child) in children {
                reached.insert(child)
                entries.append(Entry(slug: child, path: path + [name], linked: true))
                try visit(board: child, path: path + [name])
            }
        }
        try visit(board: nil, path: [projectName])
        for slug in files.subtracting(reached).sorted() {
            entries.append(Entry(slug: slug, path: [slug], linked: false))
        }
        return BoardCatalog(entries: entries)
    }
}
