import Foundation

/// Calls `onChange` when an entry in `directory` is added, removed or renamed (kqueue through a dispatch
/// source on the folder). `onChange` runs on the watcher's own queue and can fire more than once per
/// change: callers only wake a loop.
public final class FolderWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    public struct OpenError: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String { "can't watch \(path): \(String(cString: strerror(code)))" }
    }

    public init(directory: URL, onChange: @escaping @Sendable () -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw OpenError(path: directory.path, code: errno) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "linkC.folder-watcher"))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    public func stop() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
