import Foundation

/// The descriptors this process holds open on a file, found by asking the kernel for the path of
/// each one. Lets a test say how a component opened a file it does not hand back.
enum OpenDescriptors {
    struct Descriptor: CustomStringConvertible {
        let number: Int32
        let closesOnExec: Bool
        var description: String { "fd \(number) closesOnExec=\(closesOnExec)" }
    }

    static func on(_ url: URL) -> [Descriptor] {
        guard let real = realpath(url.path, nil) else { return [] }
        defer { free(real) }
        let path = String(cString: real)
        var found: [Descriptor] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for number in 0..<getdtablesize() {
            guard fcntl(number, F_GETPATH, &buffer) == 0,
                  buffer.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == path else { continue }
            let flags = fcntl(number, F_GETFD)
            found.append(Descriptor(number: number, closesOnExec: flags != -1 && flags & FD_CLOEXEC != 0))
        }
        return found
    }
}
