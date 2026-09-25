import Foundation

/// Where detail boards are created and opened: the agent tools use it now, and the app's
/// Go deeper will later.
public enum BoardDrill {
    /// The slug of `part`'s detail board on the board `parent` (nil is the overview). When the
    /// part has no detail board, or its file is missing, the board is created: a new slug from
    /// `BoardSlug.new` among the files on disk, the part's `detail` set and saved on the parent,
    /// and a new file whose `system` is the part's name, with its ghosts synced. Calling it again
    /// returns the same slug.
    public static func detail(of part: String, onBoard parent: String?, workspacePath: String) throws -> String {
        let parentStore = BoardMapStore(workspacePath: workspacePath, board: parent)
        guard let parentLoaded = try parentStore.load() else {
            throw LinkCError.parse("no board with slug \"\(parent ?? "overview")\"")
        }
        var parentMap = parentLoaded.map
        guard let partIndex = parentMap.components.firstIndex(where: { $0.name.lowercased() == part.lowercased() }) else {
            throw LinkCError.parse("no part named \"\(part)\" on the board")
        }
        let component = parentMap.components[partIndex]
        if component.outside != nil {
            throw LinkCError.parse("\"\(component.name)\" comes from the overview; go deeper from its own board")
        }

        let takenSlugs = try takenSlugs(in: workspacePath)

        let slug: String
        if let existingSlug = component.detail {
            slug = existingSlug
            try createDetailFileIfMissing(slug: slug, part: component, parent: parentMap, workspacePath: workspacePath)
        } else {
            slug = BoardSlug.new(for: component.name, under: parent, taken: takenSlugs)
            parentMap.components[partIndex].detail = slug
            try createDetailFileIfMissing(slug: slug, part: parentMap.components[partIndex], parent: parentMap, workspacePath: workspacePath)
            _ = try parentStore.save(parentMap, expecting: parentLoaded.bytes)
        }
        return slug
    }

    /// Slugs taken by existing detail-board files in the workspace. Throws when the workspace
    /// folder cannot be listed. Directories named like detail boards are not valid boards and
    /// are not included.
    public static func takenSlugs(in workspacePath: String) throws -> Set<String> {
        let folder = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        let fileNames: [String]
        do {
            fileNames = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw LinkCError.server("could not list \(folder.path): \(error.localizedDescription)")
        }
        var taken: Set<String> = []
        for name in fileNames {
            guard let slug = BoardSlug.slug(fromFileName: name) else { continue }
            var isDir: ObjCBool = false
            let itemURL = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir), !isDir.boolValue {
                taken.insert(slug)
            }
        }
        return taken
    }

    /// Loads a detail board with its ghosts synced against the board that links to it, saving
    /// the file when the sync changed it. An unlinked board loads without a sync. Throws when
    /// there's no such file.
    public static func open(_ slug: String, workspacePath: String, catalog: BoardCatalog? = nil) throws -> BoardMap {
        let store = BoardMapStore(workspacePath: workspacePath, board: slug)
        guard let loaded = try store.load() else {
            throw LinkCError.parse("no board with slug \"\(slug)\"")
        }

        let cat = try catalog ?? BoardCatalog.load(workspacePath: workspacePath, projectName: "")
        guard let entry = cat.entry(for: slug), entry.linked else {
            return loaded.map
        }

        for candidate in cat.entries {
            guard let candidateMap = try BoardMapStore(workspacePath: workspacePath, board: candidate.slug).load()?.map else { continue }
            if let linkedPart = candidateMap.components.first(where: { $0.detail == slug }) {
                if let synced = BoardGhosts.sync(detail: loaded.map, parent: candidateMap, part: linkedPart.name) {
                    _ = try store.save(synced, expecting: loaded.bytes)
                    return synced
                }
                return loaded.map
            }
        }

        return loaded.map
    }

    /// Creates the detail file for a part that the parent now links, when the file doesn't exist
    /// yet. `linkc_edit_board`'s `detail` step uses it after saving the parent.
    public static func createDetailFileIfMissing(slug: String, part: BoardComponent, parent: BoardMap, workspacePath: String) throws {
        let store = BoardMapStore(workspacePath: workspacePath, board: slug)
        guard try store.currentBytes() == nil else { return }

        var detailMap = BoardMap(system: part.name)
        if let synced = BoardGhosts.sync(detail: detailMap, parent: parent, part: part.name) {
            detailMap = synced
        } else {
            detailMap = BoardLayout.placedGhosts(detailMap)
        }
        _ = try store.save(detailMap, expecting: nil)
    }
}
