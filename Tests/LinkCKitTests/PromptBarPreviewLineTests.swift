import XCTest
import AppKit
import SwiftUI
@testable import LinkCKit

/// The line under the prompt bar sits right above the session's terminal: if its height changed as
/// the line did, the terminal would resize, and the agent's screen redraw, as the user types.
@MainActor
final class PromptBarPreviewLineTests: XCTestCase {
    private let palette = PromptBarPreviewLine.Palette(
        quiet: .gray, secondary: .gray, error: .red, accent: .orange, agent: { _ in .blue })

    private func height(of line: PromptBarLine) -> CGFloat {
        let view = NSHostingView(rootView: PromptBarPreviewLine(line: line, palette: palette).frame(width: 240))
        return view.fittingSize.height
    }

    func testTheLineKeepsOneHeightWhateverItSays() {
        let long = String(repeating: "codex skipped (no light model); ", count: 8)
        let pick = PromptBarPick(agent: .codex, tier: .standard, model: "gpt-5.6-sol", effort: .medium, reason: "implementation")
        let lines: [PromptBarLine] = [
            .idle,
            .pick(pick),
            .pick(pick.because(long)),
            .confirm(pick.because(long)),
            .error("no installed agent is free to take this task at standard — " + long),
            .opening("Opening Codex…"),
            .opened("Opened Codex — implementation"),
        ]

        let heights = lines.map(height(of:))

        XCTAssertEqual(Set(heights).count, 1, "\(zip(lines.map(\.text), heights).map { "\($1): \($0.prefix(30))" })")
        XCTAssertEqual(heights.first, PromptBarPreviewLine.height)
    }

    /// The fixed height holds one line of the line's text without clipping it.
    func testOneLineOfTextFitsTheHeight() {
        let text = NSHostingView(rootView: Text("Opened Codex").font(.system(size: 11)).fixedSize())
        XCTAssertLessThanOrEqual(text.fittingSize.height, PromptBarPreviewLine.height)
    }

    /// The tooltip carries what a truncated line leaves out.
    func testTheTooltipIsTheWholeLine() {
        let pick = PromptBarPick(agent: .codex, tier: .light, model: "gpt-5.6-luna", effort: .low, reason: "OpenCode can't take this")
        XCTAssertEqual(PromptBarLine.confirm(pick).text, "Enter again to open Codex · gpt-5.6-luna · low — OpenCode can't take this")
        XCTAssertEqual(PromptBarLine.pick(pick).text, "→ Codex · gpt-5.6-luna · low — OpenCode can't take this")
        XCTAssertEqual(PromptBarLine.error("why").text, "why")
    }
}
