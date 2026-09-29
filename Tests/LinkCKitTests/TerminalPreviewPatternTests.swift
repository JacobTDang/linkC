import XCTest
@testable import LinkCKit

/// `TerminalPreview` matches its patterns through expressions compiled once. Each matcher must
/// answer exactly what the same pattern written as a literal in `String.range(of:options:)` does,
/// on the rows a terminal draws and on rows built to be awkward: unusual digits, emoji, pattern
/// fragments cut short.
///
/// Not covered, deliberately: a combining mark, a prepend character (U+0600) or a joiner sitting
/// directly against a match boundary. There Foundation's `String` search reads the row by grapheme
/// cluster and `NSRegularExpression` by code point, so "… (٣" followed by U+0301 and "2h" is a
/// spinner timer to one and not to the other. The compiled expressions follow the code points,
/// which is what ICU documents.
final class TerminalPreviewPatternTests: XCTestCase {
    private let spinnerTokenCounter = #"… \(\d+[hms][\dhms ]*·\s*[↑↓]"#
    private let usageBanner = #"^(\d+ MCP servers? needs? authentication|Approaching [\w ]{0,24}usage limit|You've used \d+% of your session limit)\b"#
    private let spinnerTimer = #"… \(\d+[hms]"#
    private let elapsedTime = #"(?:(?<=\()|(?<=· ))\d+(\.\d+)?\s?(ms|s|m|h)(\s\d+(\.\d+)?\s?(ms|s|m|h))*\b"#

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let fragments = [
        "… (", "…", " ", "  ", "(", ")", "12s", "1m 46s", "3.5s", "45ms", "2h", "m", "h", "s", "7", "٣", "१२",
        "· ", "·", "\t", "↑", "↓", "2.5k", " tokens", "esc to interrupt", "esc to interrupt)",
        "Approaching ", "Approaching the usage limit", "usage limit", "1 MCP server needs authentication",
        "3 MCP servers need authentication", "You've used 90% of your session limit", "You've used 9% of",
        "🙂", "─", "│ ❯ ", "✻ Percolating", "⏺ Read(a.swift)",
        "Ran 24 tests (12.4s)", "(1m 46s)", "· 9s", "· 10s ", "12m of files", "ETA 4m", "\u{2028}",
    ]

    /// Rows a terminal actually shows, then a few thousand assembled from awkward fragments.
    private var corpus: [String] {
        var rows = ScreenFixture.rows(spinnerSeconds: 12) + ScreenFixture.rows(spinnerSeconds: nil)
        rows += [
            "✻ Percolating… (12s · ↓ 115 tokens)", "✳ Bunning… (2s · thinking with xhigh effort)",
            "* Loading… (3s) — finished", "· parsed 12 files… (12s", "✳ Bunning… (12s · ↓ 417 toke",
            "2 MCP servers need authentication", "⚠ Approaching Opus usage limit", "", "   ",
        ]
        var generator = SeededGenerator(state: 42)
        for _ in 0..<4000 {
            let count = Int.random(in: 1...9, using: &generator)
            rows.append((0..<count).map { _ in Self.fragments.randomElement(using: &generator)! }.joined())
        }
        // Rows a pattern is meant to match, then knocked about: the near misses are where a
        // shortcut around the pattern would go wrong.
        let matching = [
            "✻ Percolating… (46s · ↓ 2.5k tokens · esc to interrupt)", "✳ Bunning… (1m 2s · ↑ 90 tokens)",
            "3 MCP servers need authentication", "Approaching Opus usage limit",
            "You've used 90% of your session limit", "⏺ Ran 24 tests (12.4s) · 9s (1m 46s) · 1h 2m",
        ]
        for _ in 0..<4000 {
            var chars = Array(matching.randomElement(using: &generator)!)
            for _ in 0..<Int.random(in: 0...3, using: &generator) where !chars.isEmpty {
                let index = Int.random(in: 0..<chars.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: chars.remove(at: index)
                case 1: chars.insert(contentsOf: Self.fragments.randomElement(using: &generator)!, at: index)
                default: chars[index] = Self.fragments.randomElement(using: &generator)!.first!
                }
            }
            rows.append(String(chars))
        }
        return rows
    }

    private func offsets(_ range: Range<String.Index>?, in text: String) -> [Int]? {
        range.map { [text.distance(from: text.startIndex, to: $0.lowerBound), text.distance(from: text.startIndex, to: $0.upperBound)] }
    }

    func testTheSpinnerTokenCounterMatchesLikeItsLiteral() {
        for row in corpus {
            XCTAssertEqual(
                TerminalPreview.hasSpinnerTokenCounter(row),
                row.range(of: spinnerTokenCounter, options: .regularExpression) != nil,
                "row: \(row.debugDescription)"
            )
        }
    }

    func testTheUsageBannerMatchesLikeItsLiteral() {
        for row in corpus {
            XCTAssertEqual(
                TerminalPreview.hasUsageBanner(row),
                row.range(of: usageBanner, options: .regularExpression) != nil,
                "row: \(row.debugDescription)"
            )
        }
    }

    func testTheSpinnerTimerIsFoundWhereItsLiteralFindsIt() {
        for row in corpus {
            XCTAssertEqual(
                offsets(TerminalPreview.spinnerTimerRange(in: row), in: row),
                offsets(row.range(of: spinnerTimer, options: .regularExpression), in: row),
                "row: \(row.debugDescription)"
            )
        }
    }

    func testElapsedTimeIsNormalizedLikeItsLiteral() {
        for row in corpus {
            XCTAssertEqual(
                TerminalPreview.normalizingElapsedTime(row),
                row.replacingOccurrences(of: elapsedTime, with: "#", options: .regularExpression),
                "row: \(row.debugDescription)"
            )
        }
    }

    func testTheCorpusExercisesEveryMatcher() {
        let rows = corpus
        XCTAssertGreaterThan(rows.filter(TerminalPreview.hasSpinnerTokenCounter).count, 20)
        XCTAssertGreaterThan(rows.filter(TerminalPreview.hasUsageBanner).count, 20)
        XCTAssertGreaterThan(rows.filter { TerminalPreview.spinnerTimerRange(in: $0) != nil }.count, 20)
        XCTAssertGreaterThan(rows.filter { TerminalPreview.normalizingElapsedTime($0) != $0 }.count, 20)
    }

    /// The matchers exist so a sweep doesn't compile a pattern per row. The answers above would
    /// match just as well if they went back to a literal pattern per call, so this compares their
    /// cost with that, measured in the same run: interleaved, on this thread's CPU time, so machine
    /// load moves both sides alike.
    func testTheCompiledMatchersCostWellUnderAPatternCompiledPerCall() {
        let rows = ScreenFixture.rows()
        var compiled: TimeInterval = 0
        var perCall: TimeInterval = 0
        for _ in 0..<40 {
            compiled += ThreadCPUTime.elapsed {
                for row in rows {
                    _ = TerminalPreview.hasSpinnerTokenCounter(row)
                    _ = TerminalPreview.hasUsageBanner(row)
                }
            }
            perCall += ThreadCPUTime.elapsed {
                for row in rows {
                    _ = row.range(of: spinnerTokenCounter, options: .regularExpression)
                    _ = row.range(of: usageBanner, options: .regularExpression)
                }
            }
        }
        XCTAssertLessThan(compiled / perCall, 0.75,
                          "compiled \(compiled)s vs a pattern compiled per call \(perCall)s")
    }
}
