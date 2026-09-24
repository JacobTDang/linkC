import SwiftUI
import LinkCKit

/// A project's Board. Loads the map and compares it with what linkC sees running when the Board
/// appears, again when linkC's container list changes, and writes any pending edit when it goes.
/// Nothing here runs while the Board is not on screen.
struct BoardPane: View {
    let model: AppModel
    let path: String
    @State private var board: BoardModel
    @State private var watcher: BoardFileWatcher?

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
        _board = State(wrappedValue: model.board(for: path))
    }

    var body: some View {
        BoardCanvas(board: board, projectPath: path, sidebarState: model.sidebarState) {
            board.load()
            board.reconcile(with: model.discoveredThings(in: path))
            startWatching()
        }
        .onChange(of: model.toolServers?.projects) { _, _ in
            board.reconcile(with: model.discoveredThings(in: path))
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            board.saveNow()
        }
    }

    /// The Board follows its file live while it's on screen. When the watch itself can't start
    /// (the project folder is gone, say), the board still works — it just says live updates are
    /// off, rather than pretending it's watching.
    private func startWatching() {
        do {
            watcher = try BoardFileWatcher(fileURL: board.fileURL) { board.diskChanged() }
        } catch {
            board.liveUpdatesFailed(error.localizedDescription)
        }
    }
}
