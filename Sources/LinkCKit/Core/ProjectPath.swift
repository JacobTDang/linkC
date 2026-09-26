import Foundation
import Darwin

/// One canonical form for a project path, resolving symlinks and true on-disk letter case.
public enum ProjectPath {
    /// Resolves symlinks and the true on-disk letter case for a folder path.
    ///
    /// When the path does not exist or cannot be opened, returns `(path as NSString).standardizingPath`.
    public static func canonical(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let fd = open(standardized, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            return standardized
        }
        defer {
            close(fd)
        }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) >= 0 else {
            return standardized
        }
        return String(cString: buffer)
    }
}
