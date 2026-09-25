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

    init(model: AppModel, address: BoardAddress) {
        self.model = model
        self.address = address
        do {
            _board = State(wrappedValue: try model.board(for: address))
        } catch {
            let fallback = BoardModel(store: BoardMapStore(workspacePath: address.projectPath, board: address.slug))
            fallback.liveUpdatesFailed(error.localizedDescription)
            _board = State(wrappedValue: fallback)
        }
    }

    var body: some View {
        BoardCanvas(
            board: board,
            projectPath: address.projectPath,
            address: address,
            model: model,
            sidebarState: model.sidebarState
        ) {
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
