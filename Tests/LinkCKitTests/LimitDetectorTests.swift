import XCTest
@testable import LinkCKit

final class LimitDetectorTests: XCTestCase {

    // MARK: - Claude Tests

    func testClaudeUsageLimitDetected() {
        let text = "Error: You've reached your usage limit. Visit your console to upgrade."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
        XCTAssertEqual(match?.matchedPattern, "You've reached your usage limit")
        XCTAssertEqual(match?.cooldown, 15 * 60)
    }

    func testClaudeRateLimitReachedDetected() {
        let text = "API error: Rate limit reached. Please wait before retrying."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
        XCTAssertEqual(match?.matchedPattern, "Rate limit reached")
        XCTAssertEqual(match?.cooldown, 15 * 60)
    }

    func testClaudeCreditBalanceTooLowDetected() {
        let text = "Request rejected: credit balance too low to continue processing."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
        XCTAssertEqual(match?.matchedPattern, "credit balance too low")
    }

    func testClaudeUnavailableDetected() {
        let text = "Claude 3.5 Sonnet is currently unavailable. Please try again in a few minutes."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
    }

    func testClaudeReachedLimitForClaudeDetected() {
        let text = "You have reached your limit for Claude. Try again later."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
    }

    func testClaudeOutOfMessagesUntilDetected() {
        let text = "You're out of messages until 3:00 PM."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
    }

    func testClaudeExceededUsageLimitDetected() {
        let text = "You have exceeded your usage limit for this period."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .claude)
    }

    func testClaudeResetsInOrAtDetected() {
        let text1 = "Usage cap hit. Resets in 2 hours."
        let match1 = LimitDetector.detectLimit(inOutput: text1, agent: .claude)
        XCTAssertNotNil(match1)
        XCTAssertEqual(match1?.agent, .claude)

        let text2 = "Cap reached. Resets at 4:00 PM."
        let match2 = LimitDetector.detectLimit(inOutput: text2, agent: .claude)
        XCTAssertNotNil(match2)
        XCTAssertEqual(match2?.agent, .claude)
    }

    // MARK: - Codex Tests

    func testCodex429TooManyRequestsDetected() {
        let text = "HTTP 429 Too Many Requests: Server overloaded, please back off."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .codex)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .codex)
        XCTAssertEqual(match?.matchedPattern, "429 Too Many Requests")
        XCTAssertEqual(match?.cooldown, 15 * 60)
    }

    func testCodexRateLimitExceededDetected() {
        let text = "OpenAI API Error: Rate limit exceeded for organization."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .codex)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .codex)
        XCTAssertEqual(match?.matchedPattern, "Rate limit exceeded")
    }

    func testCodexQuotaExceededDetected() {
        let text = "Error: quota exceeded for current billing period."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .codex)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .codex)
        XCTAssertEqual(match?.matchedPattern, "quota exceeded")
    }

    // MARK: - Antigravity Tests

    func testAntigravityResourceExhaustedDetected() {
        let text = "RpcError: code = ResourceExhausted desc = Quota exceeded for quota metric 'Queries per minute'"
        let match = LimitDetector.detectLimit(inOutput: text, agent: .agy)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .agy)
        XCTAssertEqual(match?.matchedPattern, "ResourceExhausted")
        XCTAssertEqual(match?.cooldown, 15 * 60)
    }

    func testAntigravityQuotaLimitReachedDetected() {
        let text = "Error: quota limit reached for this session. Switch model or wait."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .agy)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .agy)
        XCTAssertEqual(match?.matchedPattern, "quota limit reached")
    }

    // MARK: - Normal Output & Isolation Tests

    func testNormalOutputReturnsNil() {
        let normalTexts: [(String, AgentKind)] = [
            ("Building target LinkCKit... Executed 459 tests, with 0 failures.", .claude),
            ("Processed 42 items in 1.2 seconds.", .codex),
            ("Workspace indexed successfully. Ready for input.", .agy),
            ("zsh: command not found: unknowncmd", .shell),
            ("", .claude),
            ("   \n\t  ", .codex),
            ("All 10 tests passed without errors.", .agy)
        ]

        for (text, agent) in normalTexts {
            let match = LimitDetector.detectLimit(inOutput: text, agent: agent)
            XCTAssertNil(match, "Expected nil for normal output on \(agent.rawValue): '\(text)'")
        }
    }

    func testCrossAgentIsolation() {
        // Claude pattern should not trigger on Codex
        let claudeText = "You've reached your usage limit."
        XCTAssertNil(LimitDetector.detectLimit(inOutput: claudeText, agent: .codex))

        // Antigravity pattern should not trigger on Claude
        let agyText = "ResourceExhausted"
        XCTAssertNil(LimitDetector.detectLimit(inOutput: agyText, agent: .claude))

        // Shell agent should never trigger limits
        XCTAssertNil(LimitDetector.detectLimit(inOutput: "Rate limit reached", agent: .shell))
        XCTAssertNil(LimitDetector.detectLimit(inOutput: "429 Too Many Requests", agent: .shell))
        XCTAssertNil(LimitDetector.detectLimit(inOutput: "ResourceExhausted", agent: .shell))
    }

    // MARK: - Case Insensitivity & Line Boundary Tests

    func testCaseInsensitiveMatching() {
        let lowerClaude = "you've reached your usage limit"
        let upperClaude = "RATE LIMIT REACHED"
        let lowerCodex = "rate limit exceeded"
        let mixedAgy = "resourceexhausted"

        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: lowerClaude, agent: .claude))
        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: upperClaude, agent: .claude))
        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: lowerCodex, agent: .codex))
        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: mixedAgy, agent: .agy))
    }

    func testLineBoundaryAndMultilineMatching() {
        let multilineClaude = """
        [info] Analyzing project structure...
        [error] Rate limit reached
        [info] Process terminated with status 1.
        """
        let matchClaude = LimitDetector.detectLimit(inOutput: multilineClaude, agent: .claude)
        XCTAssertNotNil(matchClaude)
        XCTAssertEqual(matchClaude?.matchedPattern, "Rate limit reached")

        let multilineCodexWithCRLF = "Header\r\n429 Too Many Requests\r\nFooter\r\n"
        let matchCodex = LimitDetector.detectLimit(inOutput: multilineCodexWithCRLF, agent: .codex)
        XCTAssertNotNil(matchCodex)
        XCTAssertEqual(matchCodex?.matchedPattern, "429 Too Many Requests")
    }

    func testAnsiEscapedOutputDetected() {
        let ansiClaude = "\u{001B}[31;1mError: You've reached your usage limit\u{001B}[0m"
        let match = LimitDetector.detectLimit(inOutput: ansiClaude, agent: .claude)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.matchedPattern, "You've reached your usage limit")

        let ansiCodex = "\u{001B}[33mHTTP 429 Too Many Requests\u{001B}[0m"
        let matchCodex = LimitDetector.detectLimit(inOutput: ansiCodex, agent: .codex)
        XCTAssertNotNil(matchCodex)
        XCTAssertEqual(matchCodex?.matchedPattern, "429 Too Many Requests")
    }

    // MARK: - Hook Failure Event Tests

    func testHookFailureRateLimited() {
        XCTAssertTrue(LimitDetector.isHookFailureRateLimited(kind: .stopFailure))

        XCTAssertFalse(LimitDetector.isHookFailureRateLimited(kind: .sessionStart))
        XCTAssertFalse(LimitDetector.isHookFailureRateLimited(kind: .userPromptSubmit))
        XCTAssertFalse(LimitDetector.isHookFailureRateLimited(kind: .notificationPermission))
        XCTAssertFalse(LimitDetector.isHookFailureRateLimited(kind: .notificationIdle))
        XCTAssertFalse(LimitDetector.isHookFailureRateLimited(kind: .stop))
        XCTAssertFalse(LimitDetector.isHookFailureRateLimited(kind: .sessionEnd))
    }

    // MARK: - Custom Cooldown & Conversion Tests

    func testCustomCooldownOverride() {
        let text = "Rate limit reached"
        let customCooldown: TimeInterval = 600 // 10 minutes
        let match = LimitDetector.detectLimit(inOutput: text, agent: .claude, defaultCooldown: customCooldown)
        XCTAssertEqual(match?.cooldown, 600)
    }

    func testLimitMatchToAgentLimitStatus() {
        let match = LimitMatch(agent: .claude, matchedPattern: "Rate limit reached", cooldown: 900)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let status = match.toAgentLimitStatus(now: now)

        XCTAssertEqual(status.agent, .claude)
        XCTAssertEqual(status.reason, "Rate limit reached")
        XCTAssertEqual(status.limitedAt, now)
        XCTAssertEqual(status.cooldownExpiresAt, Date(timeIntervalSince1970: 1_000_900))
    }
}
