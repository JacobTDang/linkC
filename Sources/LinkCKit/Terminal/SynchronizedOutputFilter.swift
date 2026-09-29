import Foundation

/// Strips complete mode-2026 (synchronized output) toggles — `ESC [ ? 2026 h` and `ESC [ ? 2026 l` —
/// from a terminal byte stream and tracks which mode the stream last set.
///
/// SwiftTerm runs a display pass on every end of frame and offers no way to suppress it, so a
/// terminal nobody can see gets the stream with the toggles removed and is put back in the mode
/// the stream left it in when it is shown again.
///
/// Only the exact sequence is recognised. A parameter list that mixes 2026 with other modes
/// (`ESC [ ? 2026 ; 25 h`) passes through to SwiftTerm: it is rare, costs at most one display pass
/// a second, and the mode is reconciled when the terminal is shown again.
struct SynchronizedOutputFilter {
    /// The mode the stream last set — the mode SwiftTerm would be in had it seen every toggle.
    /// Seeded from SwiftTerm's own mode when a hidden stretch begins.
    var active = false
    /// The tail of a chunk that could still become a toggle, or that ends inside any other control
    /// sequence, held back until the next chunk. Holding the second kind too means the mode restored
    /// on reattach never lands inside a sequence SwiftTerm's parser is still reading.
    private(set) var carry: [UInt8] = []

    /// `ESC [ ? 2026`: what a start and an end toggle have in common; the byte after it tells them apart.
    private static let introducer = Array("\u{1b}[?2026".utf8)
    private static let startByte = UInt8(ascii: "h")
    private static let endByte = UInt8(ascii: "l")
    private static let toggleLength = introducer.count + 1
    /// The longest unfinished control sequence held back; anything longer passes through as it is.
    private static let longestHeldSequence = 64

    private enum Match { case start, end, partial, other }

    /// `chunk` with every complete toggle removed. A trailing partial toggle is held in `carry`.
    mutating func filter(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        guard !carry.isEmpty else {
            return chunk.withUnsafeBufferPointer { scan($0) }
        }
        let joined = carry + chunk
        carry.removeAll(keepingCapacity: true)
        return joined.withUnsafeBufferPointer { scan($0) }
    }

    /// The held-back tail, removed from the filter — for a caller that gives up waiting for the rest.
    mutating func takeCarry() -> [UInt8] {
        defer { carry.removeAll(keepingCapacity: true) }
        return carry
    }

    /// Looks only for ESC bytes and copies the runs between them, so text costs a `memchr` and
    /// a copy, not a comparison per byte.
    private mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        guard let base = bytes.baseAddress else { return [] }
        let introducer = Self.introducer
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var copiedTo = 0
        var searchFrom = 0
        while searchFrom < bytes.count,
              let found = memchr(base + searchFrom, Int32(introducer[0]), bytes.count - searchFrom) {
            let escape = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
            let remaining = bytes.count - escape
            let match = Self.match(base + escape, remaining: remaining, introducer: introducer)
            switch match {
            case .start, .end:
                output.append(contentsOf: UnsafeBufferPointer(start: base + copiedTo, count: escape - copiedTo))
                active = match == .start
                copiedTo = escape + Self.toggleLength
                searchFrom = copiedTo
            case .partial:
                output.append(contentsOf: UnsafeBufferPointer(start: base + copiedTo, count: escape - copiedTo))
                carry = Array(UnsafeBufferPointer(start: base + escape, count: remaining))
                return output
            case .other:
                searchFrom = escape + 1
            }
        }
        output.append(contentsOf: UnsafeBufferPointer(start: base + copiedTo, count: bytes.count - copiedTo))
        return output
    }

    /// What the `remaining` bytes from an ESC on begin with: a whole toggle, the first part of one
    /// or of any control sequence the chunk ends inside (`partial`), or something else.
    private static func match(_ escape: UnsafePointer<UInt8>, remaining: Int, introducer: [UInt8]) -> Match {
        for offset in 1..<min(remaining, introducer.count) where escape[offset] != introducer[offset] {
            return endsInsideAControlSequence(escape, remaining: remaining) ? .partial : .other
        }
        guard remaining > introducer.count else { return .partial }
        switch escape[introducer.count] {
        case startByte: return .start
        case endByte: return .end
        default: return endsInsideAControlSequence(escape, remaining: remaining) ? .partial : .other
        }
    }

    /// Whether the bytes from an ESC to the end of the chunk are a control sequence (`ESC [`) still
    /// waiting for its final byte: only parameter and intermediate bytes (0x20–0x3F) after the `[`.
    private static func endsInsideAControlSequence(_ escape: UnsafePointer<UInt8>, remaining: Int) -> Bool {
        guard remaining >= 2, remaining <= longestHeldSequence, escape[1] == UInt8(ascii: "[") else { return false }
        for offset in 2..<remaining where !(0x20...0x3F).contains(escape[offset]) {
            return false
        }
        return true
    }
}
