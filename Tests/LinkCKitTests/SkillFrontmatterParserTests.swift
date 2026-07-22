import XCTest
@testable import LinkCKit

/// Line-based SKILL.md frontmatter parsing — matches every real skill on disk (single-line
/// name/description, quoted or bare). Anything it can't read confidently returns nil and the
/// skill is skipped, never mis-rendered.
final class SkillFrontmatterParserTests: XCTestCase {

    func testQuotedDescription() throws {
        let contents = """
        ---
        name: red-team
        description: "Use this whenever you are asked to critique, review, stress-test."
        ---
        # Body
        """
        let fm = try XCTUnwrap(SkillFrontmatterParser.parse(contents))
        XCTAssertEqual(fm.name, "red-team")
        XCTAssertEqual(fm.description, "Use this whenever you are asked to critique, review, stress-test.")
    }

    func testBareDescriptionAndExtraKeysIgnored() throws {
        let contents = """
        ---
        name: test-driven-development
        description: Use when implementing any feature or bugfix, before writing implementation code
        license: MIT
        ---
        """
        let fm = try XCTUnwrap(SkillFrontmatterParser.parse(contents))
        XCTAssertEqual(fm.name, "test-driven-development")
        XCTAssertTrue(fm.description.hasPrefix("Use when implementing"))
    }

    func testCRLFLineEndings() throws {
        let contents = "---\r\nname: a\r\ndescription: b\r\n---\r\n"
        let fm = try XCTUnwrap(SkillFrontmatterParser.parse(contents))
        XCTAssertEqual(fm.name, "a")
        XCTAssertEqual(fm.description, "b")
    }

    func testUnparseableInputsAreNil() {
        XCTAssertNil(SkillFrontmatterParser.parse(""))
        XCTAssertNil(SkillFrontmatterParser.parse("# Just markdown, no frontmatter"))
        XCTAssertNil(SkillFrontmatterParser.parse("---\nname: only-name\n---\n"), "missing description")
        XCTAssertNil(SkillFrontmatterParser.parse("---\nname: x\ndescription: y\n"), "unclosed block")
    }

    func testBodyStripsFrontmatterBlock() {
        let contents = "---\nname: a\ndescription: b\n---\n\n# The Skill\n\nDo the thing."
        XCTAssertEqual(SkillFrontmatterParser.body(contents), "# The Skill\n\nDo the thing.")
    }

    func testBodyWithoutFrontmatterIsWholeContents() {
        XCTAssertEqual(SkillFrontmatterParser.body("# Bare markdown"), "# Bare markdown")
        XCTAssertEqual(SkillFrontmatterParser.body("---\nunclosed: block\n"), "---\nunclosed: block\n",
                       "an unclosed frontmatter block isn't frontmatter — show everything")
    }
}
