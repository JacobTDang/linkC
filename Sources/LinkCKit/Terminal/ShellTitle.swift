import Foundation

/// The name a plain terminal shows for the folder it is in.
public enum ShellTitle {
    /// "~" for `home`, "/" for the root, otherwise the folder's last path component.
    public static func name(forDirectory directory: String, home: String) -> String {
        let path = (directory as NSString).standardizingPath
        if path == (home as NSString).standardizingPath { return "~" }
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }
}
