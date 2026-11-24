import AppKit
import XCTest
@testable import LinkCKit

final class TerminalFontTests: XCTestCase {
    func testTheSymbolsOnlyNerdFontWinsOverAnyOther() {
        let families = ["Menlo", "JetBrainsMono Nerd Font", "JetBrainsMono Nerd Font Mono", "Symbols Nerd Font Mono"]
        XCTAssertEqual(TerminalFont.nerdFamily(in: families), "Symbols Nerd Font Mono")
    }

    /// A Mono family draws each icon in one cell; the plain family draws it wider than the cell.
    func testAMonoNerdFontWinsOverItsWiderAndProportionalSiblings() {
        let families = ["JetBrainsMono Nerd Font Propo", "JetBrainsMono Nerd Font", "JetBrainsMono Nerd Font Mono"]
        XCTAssertEqual(TerminalFont.nerdFamily(in: families), "JetBrainsMono Nerd Font Mono")
    }

    func testAPlainNerdFontIsUsedWhenNoMonoOneIsInstalled() {
        XCTAssertEqual(TerminalFont.nerdFamily(in: ["Hack Nerd Font Propo", "Hack Nerd Font"]), "Hack Nerd Font")
    }

    func testNoFamilyIsPickedWithoutANerdFont() {
        XCTAssertNil(TerminalFont.nerdFamily(in: ["Menlo", "SF Pro", "Hack Nerd Font Propo"]))
    }

    func testWithANerdFontTheTerminalDrawsSFMonoFallingBackToIt() throws {
        let made = TerminalFont.make(size: 12.5, sfMonoFolder: TerminalFont.sfMonoFolder,
                                     families: ["Menlo", "JetBrainsMono Nerd Font Mono"])
        XCTAssertNil(made.problem)
        XCTAssertEqual(made.font.fontName, "SFMono-Regular")
        XCTAssertEqual(made.font.pointSize, 12.5)
        let cascade = try XCTUnwrap(made.font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.first?.object(forKey: .family) as? String, "JetBrainsMono Nerd Font Mono")
    }

    func testWithoutANerdFontTheTerminalKeepsTheSystemMonospacedFontAndSaysWhy() throws {
        let made = TerminalFont.make(size: 12.5, sfMonoFolder: TerminalFont.sfMonoFolder, families: ["Menlo"])
        XCTAssertEqual(made.font, NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        XCTAssertTrue(try XCTUnwrap(made.problem).contains("no Nerd Font"))
    }

    func testWithoutSFMonoFilesTheTerminalKeepsTheSystemMonospacedFontAndNamesTheFolder() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let made = TerminalFont.make(size: 12.5, sfMonoFolder: empty, families: ["JetBrainsMono Nerd Font Mono"])
        XCTAssertEqual(made.font, NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        XCTAssertTrue(try XCTUnwrap(made.problem).contains(empty.path))
    }

    /// The bug: SF Mono as the system monospaced font ignores a fallback list, so icons in the
    /// U+E000–U+F8FF range (folders, json, branch) drew as the LastResort `?` box. Needs a Nerd
    /// Font installed on this Mac, so CI skips it.
    @MainActor func testAFolderIconDrawsFromTheNerdFontInEveryStyle() throws {
        let installed = NSFontManager.shared.availableFontFamilies
        guard let family = TerminalFont.nerdFamily(in: installed) else { throw XCTSkip("no Nerd Font installed") }
        let made = TerminalFont.make(size: 12.5, sfMonoFolder: TerminalFont.sfMonoFolder, families: installed)
        XCTAssertNil(made.problem)
        let manager = NSFontManager.shared
        let styles: [NSFontTraitMask] = [[], .boldFontMask, .italicFontMask, [.boldFontMask, .italicFontMask]]
        for traits in styles {
            let font = traits.isEmpty ? made.font : manager.convert(made.font, toHaveTrait: traits)
            let drawnWith = try Self.fontDrawing("\u{E5FF}", with: font)
            XCTAssertNotEqual(drawnWith, "LastResort", "traits \(traits.rawValue)")
            XCTAssertEqual(NSFont(name: drawnWith, size: 12.5)?.familyName, family,
                           "traits \(traits.rawValue) drew with \(drawnWith)")
        }
    }

    /// Only icons come from the Nerd Font: a character SF Mono lacks outside the icon ranges, such as
    /// a frame of an agent's spinner, keeps the system's own fallback, so the spinner never changes face.
    @MainActor func testOnlyIconsComeFromTheNerdFont() throws {
        let installed = NSFontManager.shared.availableFontFamilies
        guard let family = TerminalFont.nerdFamily(in: installed) else { throw XCTSkip("no Nerd Font installed") }
        let made = TerminalFont.make(size: 12.5, sfMonoFolder: TerminalFont.sfMonoFolder, families: installed)
        for symbol in ["\u{2736}", "\u{276F}", "\u{2819}"] {
            let drawnWith = try Self.fontDrawing(symbol, with: made.font)
            XCTAssertNotEqual(NSFont(name: drawnWith, size: 12.5)?.familyName, family, "\(symbol) drew with \(drawnWith)")
        }
        XCTAssertEqual(NSFont(name: try Self.fontDrawing("\u{F0354}", with: made.font), size: 12.5)?.familyName, family,
                       "an icon past U+F0000 still comes from the Nerd Font")
    }

    /// A Nerd Font named with the short "NF" (MesloLGS NF, which Powerlevel10k installs) counts too.
    func testANerdFontWithAShortNFNameCounts() {
        XCTAssertEqual(TerminalFont.nerdFamily(in: ["Menlo", "MesloLGS NF"]), "MesloLGS NF")
        XCTAssertEqual(TerminalFont.nerdFamily(in: ["Hack NF", "Hack NFM", "Hack NFP"]), "Hack NFM")
        XCTAssertNil(TerminalFont.nerdFamily(in: ["Hack NFP", "INFO Sans", "ConfNF"]))
    }

    private static func fontDrawing(_ text: String, with font: NSFont) throws -> String {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let run = try XCTUnwrap((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
        let runFont = try XCTUnwrap((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName])
        return CTFontCopyPostScriptName(runFont as! CTFont) as String
    }
}
