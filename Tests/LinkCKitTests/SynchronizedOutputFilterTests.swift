import AppKit
import XCTest
@testable import LinkCKit

private let escape = "\u{1b}"

private struct FilterRun {
    var output: [UInt8] = []
    var carry: [UInt8] = []
    var active: Bool

    var text: String { String(decoding: output, as: UTF8.self) }
}

private func filtered(_ chunks: [[UInt8]], active: Bool = false) -> FilterRun {
    var filter = SynchronizedOutputFilter()
    filter.active = active
    var result = FilterRun(active: active)
    for chunk in chunks {
        result.output += filter.filter(chunk[...])
    }
    result.carry = filter.carry
    result.active = filter.active
    return result
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

final class SynchronizedOutputFilterTests: XCTestCase {

    func testCompleteToggleSequencesAreStrippedAndTheLastOneWins() {
        let stripped = filtered([bytes("\(escape)[?2026hone\(escape)[?2026ltwo\(escape)[?2026hthree")])
        XCTAssertEqual(stripped.text, "onetwothree")
        XCTAssertTrue(stripped.active)
        XCTAssertTrue(stripped.carry.isEmpty)

        let ended = filtered([bytes("\(escape)[?2026hframe\(escape)[?2026l")], active: false)
        XCTAssertEqual(ended.text, "frame")
        XCTAssertFalse(ended.active)
    }

    func testAToggleHeldOverFromTheLastChunkCompletesInTheNext() {
        var filter = SynchronizedOutputFilter()
        XCTAssertEqual(String(decoding: filter.filter(bytes("abc\(escape)[?20")[...]), as: UTF8.self), "abc")
        XCTAssertEqual(filter.carry, bytes("\(escape)[?20"))
        XCTAssertFalse(filter.active, "a toggle that has not completed has not happened")

        XCTAssertEqual(String(decoding: filter.filter(bytes("26h def")[...]), as: UTF8.self), " def")
        XCTAssertTrue(filter.carry.isEmpty)
        XCTAssertTrue(filter.active)
    }

    func testAHeldOverPartialThatDoesNotCompleteIsPassedOnUnchanged() {
        var filter = SynchronizedOutputFilter()
        _ = filter.filter(bytes("\(escape)[?20")[...])
        XCTAssertEqual(String(decoding: filter.filter(bytes("04hx")[...]), as: UTF8.self), "\(escape)[?2004hx")
        XCTAssertTrue(filter.carry.isEmpty)
        XCTAssertFalse(filter.active)
    }

    func testOtherSequencesPassThroughUntouched() {
        let others = [
            "\(escape)[?2004h", "\(escape)[?1049l", "\(escape)[?25l", "\(escape)[?2027h", "\(escape)[2026h",
            "\(escape)[?202h", "\(escape)[?20260h", "\(escape)[?12026l", "\(escape)[31mred\(escape)[0m",
            "\(escape)\(escape)[?2004h", "\(escape)]0;title\u{7}", "no escape at all",
        ]
        for sequence in others {
            for seeded in [false, true] {
                let result = filtered([bytes("a\(sequence)b")], active: seeded)
                XCTAssertEqual(result.text, "a\(sequence)b", "\(sequence.debugDescription) must pass through")
                XCTAssertEqual(result.active, seeded, "\(sequence.debugDescription) must not touch the tracked mode")
                XCTAssertTrue(result.carry.isEmpty)
            }
        }
    }

    /// A parameter list that mixes 2026 with other modes is left to SwiftTerm: it is rare, costs at
    /// most one display pass a second, and the mode is reconciled when the terminal is shown again.
    func testACombinedParameterListIsNotFiltered() {
        let result = filtered([bytes("\(escape)[?2026;25h")])
        XCTAssertEqual(result.text, "\(escape)[?2026;25h")
        XCTAssertFalse(result.active)
    }

    func testOutputIsIdenticalHoweverTheStreamIsSplit() {
        let streams = [
            "\(escape)[?2026habc\(escape)[31mred\(escape)[0m\(escape)[?2004h\(escape)[?2026l"
                + "\(escape)\(escape)[?2026hxyz\(escape)[?20x\(escape)[?2026;25h\(escape)[?20260h\(escape)[?2026l tail",
            "\(escape)[?2026lpre\(escape)[?2026hmid\(escape)[?2026lpost\(escape)[?2026hend\(escape)[?202",
        ].map(bytes)

        for stream in streams {
            let whole = filtered([stream])
            var differing: [String] = []
            func check(_ chunks: [[UInt8]], _ label: String) {
                let split = filtered(chunks)
                if split.output != whole.output || split.carry != whole.carry || split.active != whole.active {
                    differing.append(label)
                }
            }
            for first in 0...stream.count {
                check([Array(stream[..<first]), Array(stream[first...])], "\(first)")
                for second in first...stream.count {
                    check([Array(stream[..<first]), Array(stream[first..<second]), Array(stream[second...])],
                          "\(first),\(second)")
                }
            }
            XCTAssertEqual(differing, [], "splits that changed the output of \(String(decoding: stream, as: UTF8.self).debugDescription)")
        }
    }

    func testTakingTheHeldOverPartialEmptiesIt() {
        var filter = SynchronizedOutputFilter()
        _ = filter.filter(bytes("abc\(escape)[?2026")[...])
        XCTAssertEqual(filter.takeCarry(), bytes("\(escape)[?2026"))
        XCTAssertTrue(filter.carry.isEmpty)
        XCTAssertEqual(String(decoding: filter.filter(bytes("h")[...]), as: UTF8.self), "h",
                       "a taken partial is gone: the next chunk starts fresh")
    }

    /// Text with no escape in it costs the filter one search and one copy, so it must stay within a
    /// small multiple of a plain copy of the same bytes — measured in the same run, so a slower or
    /// busier machine (or ThreadSanitizer) moves both.
    func testFilteringPlainTextCostsAboutAsMuchAsCopyingIt() {
        var text = ""
        for line in 0..<6000 {
            text += "streamed line number \(line) with plain words only\r\n"
        }
        let output = Array(text.utf8.prefix(128 * 1024))[...]
        var filter = SynchronizedOutputFilter()
        let passes = 50
        var copied = 0

        var filtering = TimeInterval.greatestFiniteMagnitude
        var copying = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<5 {
            filtering = min(filtering, ThreadCPUTime.elapsed {
                for _ in 0..<passes { _ = filter.filter(output) }
            })
            copying = min(copying, ThreadCPUTime.elapsed {
                for _ in 0..<passes { copied += output.withUnsafeBufferPointer { Array($0) }.count }
            })
        }

        XCTAssertEqual(copied, 5 * passes * output.count)
        XCTAssertLessThan(filtering, copying * 20,
                          String(format: "filtering %d passes of 128 KB took %.6fs; copying them took %.6fs", passes, filtering, copying))
    }

    /// Filtering must stay a small fraction of parsing the same bytes — measured in the same run on
    /// escape-dense output (the worst case for the filter), so a slower or busier machine moves both.
    @MainActor
    func testFilteringCostsAFractionOfParsingTheSameOutput() {
        var chunk = ""
        for line in 0..<6000 {
            chunk += "\(escape)[32mstreamed line \(line)\(escape)[0m\r\n"
        }
        let output = Array(chunk.utf8.prefix(128 * 1024))[...]
        let terminal = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460)).getTerminal()
        var filter = SynchronizedOutputFilter()

        var filtering = TimeInterval.greatestFiniteMagnitude
        var parsing = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<5 {
            filtering = min(filtering, ThreadCPUTime.elapsed { _ = filter.filter(output) })
            parsing = min(parsing, ThreadCPUTime.elapsed { terminal.feed(buffer: output) })
        }

        XCTAssertLessThan(filtering * 4, parsing,
                          String(format: "filtering 128 KB took %.6fs; parsing it took %.6fs", filtering, parsing))
    }
}
