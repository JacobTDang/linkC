import SwiftUI
import LinkCKit

/// A project's Board. Loads the map and compares it with what linkC sees running when the Board
/// appears, again when linkC's container list changes, and writes any pending edit when it goes.
/// Nothing here runs while the Board is not on screen.
struct BoardPane: View {
    let model: AppModel
    let path: String

    var body: some View {
        let address = model.currentAddress(for: path)
        BoardPaneContent(model: model, address: address)
            .id(address)
    }
}

private struct BoardPaneContent: View {
    let model: AppModel
    let address: BoardAddress
    @State private var board: BoardModel
    @State private var watcher: BoardFileWatcher?
    /// Why syncing this detail board's ghosts with the overview failed, for the Board's banner.
    @State private var openError: String?

    init(model: AppModel, address: BoardAddress) {
        self.model = model
        self.address = address
        _board = State(wrappedValue: model.board(for: address))
    }

    var body: some View {
        BoardCanvas(
            board: board,
            projectPath: address.projectPath,
            address: address,
            model: model,
            sidebarState: model.sidebarState,
            openError: openError
        ) {
            syncGhosts()
            board.load()
            board.reconcile(with: model.discoveredThings(in: address.projectPath))
            startWatching()
        }
        .onChange(of: model.toolServers?.projects) { _, _ in
            board.reconcile(with: model.discoveredThings(in: address.projectPath))
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            board.saveNow()
        }
    }

    /// A detail board's ghosts follow the overview, so they're synced (and saved when they
    /// changed) every time the board appears, before it loads. The overview has none.
    private func syncGhosts() {
        guard let slug = address.slug else { return }
        do {
            _ = try BoardDrill.open(slug, workspacePath: address.projectPath)
            openError = nil
        } catch {
            NSLog("[linkC] board %@: ghost sync failed — %@", slug, String(describing: error))
            openError = error.localizedDescription
        }
    }

    /// The Board follows its file live while it's on screen. Stops any watcher already running
    /// first — `prepare` can fire more than once per `onDisappear` (a scene change, say), and a
    /// second watcher left running alongside the first would double-fire `diskChanged()`. When
    /// the watch itself can't start (the project folder is gone, say), the board still works — it
    /// just says live updates are off, rather than pretending it's watching.
    private func startWatching() {
        watcher?.stop()
        watcher = nil
        do {
            watcher = try BoardFileWatcher(fileURL: board.fileURL) { board.diskChanged() }
            board.liveUpdatesStarted()
        } catch {
            board.liveUpdatesFailed(error.localizedDescription)
        }
    }
}
