import Foundation

/// Calls `onChange` on the main queue whenever `fileURL` may have changed: its folder's entries
/// change (an atomic save renames into it), or the file itself is written, extended, renamed or
/// deleted (an in-place save). Event-driven through kqueue; nothing is polled. `onChange` can
/// fire more than once per save: callers compare bytes. `stop()` ends it; so does deinit.
public final class BoardFileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let onChange: @MainActor () -> Void

    /// Owns every dispatch source and descriptor below; only this queue ever touches them, so
    /// the folder event, the file event and `stop()`'s teardown never race each other.
    private let queue = DispatchQueue(label: "linkc.board-file-watcher")
    /// Tags `queue`, so `teardown()` can tell whether it is already running on it — see there.
    private let queueKey = DispatchSpecificKey<Void>()
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    /// Gates delivery of `onChange`. Touched only on the main queue: `stop()`/`deinit` set it
    /// there, and a firing callback checks it there too, so one already in flight when `stop()`
    /// runs is still cut off before it reaches `onChange`.
    private var stopped = false

    public init(fileURL: URL, onChange: @escaping @MainActor () -> Void) throws {
        self.fileURL = fileURL
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())

        let folderPath = fileURL.deletingLastPathComponent().path
        let folderDescriptor = open(folderPath, O_EVTONLY)
        guard folderDescriptor != -1 else {
            let message = String(cString: strerror(errno))
            throw LinkCError.server("could not watch \(folderPath): \(message)")
        }

        let folder = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folderDescriptor, eventMask: .write, queue: queue)
        folder.setEventHandler { [weak self] in self?.folderChanged() }
        folder.setCancelHandler { close(folderDescriptor) }
        folderSource = folder
        folder.resume()

        queue.sync { openFileSource() }
    }

    deinit {
        markStopped()
        teardown()
    }

    public func stop() {
        markStopped()
        teardown()
    }

    private func markStopped() {
        if Thread.isMainThread {
            stopped = true
        } else {
            DispatchQueue.main.sync { stopped = true }
        }
    }

    /// Cancels both sources. Safe to call from `deinit`, which can run on `queue` itself: the
    /// last strong reference to this watcher can be released from inside its own event handler
    /// (`[weak self] in self?.folderChanged()` briefly holds one for the call), and if nothing
    /// else outlives that moment, `deinit` fires right there, synchronously, on `queue`. A plain
    /// `queue.sync` here would then deadlock — a serial queue can never `sync` into itself. When
    /// `queueKey` shows we're already running on `queue`, cancelling inline is not just safe but
    /// correct: we are already exactly as serialized as `sync` would make us.
    private func teardown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cancelSources()
        } else {
            queue.sync { cancelSources() }
        }
    }

    private func cancelSources() {
        folderSource?.cancel()
        folderSource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    // MARK: - Confined to `queue`

    private func folderChanged() {
        if fileSource == nil { openFileSource() }
        fire()
    }

    private func fileChanged(_ event: DispatchSource.FileSystemEvent) {
        if event.contains(.delete) || event.contains(.rename) {
            fileSource?.cancel()
            fileSource = nil
            openFileSource()   // an atomic save has usually already renamed the new file into place
        }
        fire()
    }

    /// Opens a fresh watch on the file itself, when it exists and isn't already watched.
    private func openFileSource() {
        guard fileSource == nil else { return }
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor != -1 else { return }   // no file yet; the folder watch will try again
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            fileChanged(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.resume()
    }

    private func fire() {
        Task { @MainActor [weak self] in
            guard let self, !stopped else { return }
            onChange()
        }
    }
}
