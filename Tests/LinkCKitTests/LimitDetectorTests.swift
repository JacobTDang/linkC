import XCTest
@testable import LinkCKit

final class LimitDetectorTests: XCTestCase {

    // MARK: - linkC's own text

    /// A brief linkC typed into a terminal can quote a limit phrase — the reroute briefs it used to
    /// invent did exactly that — and the terminal echoes it straight back. Reading that as the
    /// agent's own exhaustion banner recorded a limit nobody hit.
    func testAPhraseLinkCTypedIsNotTheAgentsOwnBanner() {
        let brief = "[linkC task 47608277 from Claude Code]\nTask rerouted due to rate limit (You've reached your usage limit). Inspect .linkc/HANDOFF.md and continue."
        let screen = "❯ \n\(brief)\n"

        XCTAssertNil(
            LimitDetector.detectLimit(inOutput: screen, agent: .claude, ignoringInjected: [brief]),
            "linkC's own injected text is not the agent reporting a limit"
        )
        XCTAssertNotNil(
            LimitDetector.detectLimit(inOutput: screen, agent: .claude),
            "the same screen without the guard still matches — the guard is what suppresses it"
        )
    }

    /// The agent's own banner still counts while an injected brief sits on the same screen.
    func testABannerOutsideInjectedTextIsStillDetected() {
        let brief = "[linkC task ABCD1234 from Codex]\nRefactor the migrations and report back."
        let screen = "\(brief)\n⏺ Error: You've reached your usage limit · resets 3pm\n"

        let match = LimitDetector.detectLimit(inOutput: screen, agent: .claude, ignoringInjected: [brief])
        XCTAssertEqual(match?.matchedPattern, "You've reached your usage limit")
    }

    /// A long injected line is wrapped by the terminal, so each screen row is only a fragment of
    /// what linkC typed — the fragments must be ignored too.
    func testAWrappedInjectedLineIsIgnored() {
        let brief = "[linkC task 47608277 from Claude Code] Task rerouted due to rate limit (You've reached your usage limit). Continue from the handoff."
        let wrapped = "[linkC task 47608277 from Claude Code] Task rerouted due to rate limit (You've\nreached your usage limit). Continue from the handoff."

        XCTAssertNil(LimitDetector.detectLimit(inOutput: wrapped, agent: .claude, ignoringInjected: [brief]))
    }

    /// `detectLimit` never takes a clock at all — this guard is not bounded by time, unlike the
    /// rejected `injectedEchoWindow` attempt. An echo of a brief quoting a limit phrase is not a
    /// limit no matter how long it has sat on screen, because suppression here is entirely by
    /// content.
    func testAnEchoOfABriefIsNotALimitNoMatterHowOldNoClockInvolved() {
        let brief = "[linkC task 9910 from Claude Code] Task rerouted due to rate limit (You've reached your usage limit). Continue from the handoff."
        let screen = "❯ \n\(brief)\n"

        XCTAssertNil(LimitDetector.detectLimit(inOutput: screen, agent: .claude, ignoringInjected: [brief]))
    }

    /// This is the exact defect in the rejected "drop any row contained in any recent injection"
    /// approach: a standalone banner row that is JUST the phrase is also, trivially, a literal
    /// substring of a brief that quotes the same phrase, so dropping any row found inside any
    /// injection dropped the real banner too. Only the brief's own occurrence may be removed —
    /// found once, deleted once — leaving the separate banner intact for the regex to catch.
    func testAStandaloneBannerSurvivesAlongsideABriefQuotingTheSamePhrase() {
        let brief = "[linkC task 47608277 from Claude Code]\nTask rerouted due to rate limit (You've reached your usage limit). Inspect .linkc/HANDOFF.md and continue."
        let banner = "You've reached your usage limit"
        let screen = "❯ \n\(brief)\n\n\(banner)\n"

        let match = LimitDetector.detectLimit(inOutput: screen, agent: .claude, ignoringInjected: [brief])
        XCTAssertEqual(
            match?.matchedPattern, "You've reached your usage limit",
            "the brief's one occurrence of the phrase is removed but the separate banner row still matches"
        )
    }

    /// A terminal wrap can land mid-word, with no space at the break at all — not just at a
    /// convenient word boundary. Matching must be whitespace-insensitive enough to see through
    /// that. The word split here ("Continue" into "Cont" + "inue") is deliberately NOT the trigger
    /// phrase itself: if whitespace-insensitive matching ever regressed to only treating a literal
    /// space as whitespace (missing the inserted newline), the whole injected entry would fail to
    /// match as one contiguous span, nothing would be removed, and the untouched, fully intact
    /// "You've reached your usage limit" earlier in the same line would then be read as a real
    /// banner — which is exactly the failure this test is built to catch.
    func testAMidWordWrappedInjectedLineIsIgnored() {
        let brief = "[linkC task 9182 from Claude Code] Task rerouted due to rate limit (You've reached your usage limit). Continue from the handoff."
        let wrapped = "[linkC task 9182 from Claude Code] Task rerouted due to rate limit (You've reached your usage limit). Cont\ninue from the handoff."

        XCTAssertNil(LimitDetector.detectLimit(inOutput: wrapped, agent: .claude, ignoringInjected: [brief]))
    }

    /// An injected entry only partially on screen — its first half already scrolled off — must
    /// suppress nothing at all. A banner sitting in the still-visible half is still detected.
    func testAPartiallyScrolledInjectedEntrySuppressesNothing() {
        let brief = "[linkC task 55 from Claude Code] Task rerouted due to rate limit (You've reached your usage limit). Continue from the handoff."
        // Only the tail of the brief remains on screen; the banner below it is fully visible.
        let visibleHalf = "your usage limit). Continue from the handoff.\n⏺ Error: You've reached your usage limit\n"

        let match = LimitDetector.detectLimit(inOutput: visibleHalf, agent: .claude, ignoringInjected: [brief])
        XCTAssertEqual(
            match?.matchedPattern, "You've reached your usage limit",
            "an injected entry not fully present on screen must suppress nothing"
        )
    }

    /// Every real injection carries a marker (a task frame, a peer note, a `/model` command), so an
    /// injected entry is never a bare limit phrase. That is what keeps once-by-content removal from
    /// latching onto genuine output — an invariant of the callers, not of this function. Lock the
    /// safe behaviour in as a contract: even a bare phrase must consume only its own occurrence.
    func testABareInjectedPhraseConsumesOnlyItsOwnOccurrence() {
        let bare = "You've reached your usage limit"
        let screen = "\(bare)\n⏺ Error: You've reached your usage limit · resets 3pm\n"

        let match = LimitDetector.detectLimit(inOutput: screen, agent: .claude, ignoringInjected: [bare])
        XCTAssertEqual(
            match?.matchedPattern, "You've reached your usage limit",
            "removing the echo must leave the agent's own banner detectable"
        )
    }

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

    /// A cap banner is exhaustion; the reset sentence beside it is incidental, not the signal.
    func testClaudeUsageCapBannerDetected() {
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
    func testCodexUsageCapBannerDetected() {
        let text = "You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:05 PM."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .codex)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.agent, .codex)
        XCTAssertEqual(match?.matchedPattern, "You've reached your usage limit")
        // No explicit cooldown specified for claude/codex banner rule in general, so default is 15 mins (15 * 60)
        XCTAssertEqual(match?.cooldown, 15 * 60)
    }

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

    // MARK: - Cursor Tests
    //
    // Limit phrases are split across `+` in these sources only so that a diff of this file, shown in
    // an agent's terminal, never reads as a live banner to linkC's own detector.

    /// Cursor's real usage-cap error, as its agent transcript and terminal show it once the account's
    /// model quota is spent. linkC missed it, so it kept routing work to Cursor that failed at once.
    func testCursorUsageCapErrorDetected() {
        let text = "Error: You've hit your " + "usage limit\n"
            + "You've saved $71 on API model usage this month with Pro. Switch to a different\n"
            + "model or set a Spend Limit to continue with this model."
        let match = LimitDetector.detectLimit(inOutput: text, agent: .cursor)
        XCTAssertNotNil(match, "Cursor's own cap error must record it as limited")
        XCTAssertEqual(match?.agent, .cursor)
    }

    /// A spent quota does not come back in fifteen minutes, so Cursor's cap waits hours before linkC
    /// tries it again instead of failing a routed task every quarter hour until the quota resets.
    func testCursorUsageCapWaitsHoursNotMinutes() {
        let cap = LimitDetector.detectLimit(inOutput: "Error: You've hit your " + "usage limit", agent: .cursor)
        XCTAssertEqual(cap?.cooldown, 6 * 3600)
        let rate = LimitDetector.detectLimit(inOutput: "Rate limit " + "reached.", agent: .cursor)
        XCTAssertEqual(rate?.cooldown, 15 * 60, "an ordinary rate limit keeps the short cooldown")
    }

    func testCursorRateLimitStillDetected() {
        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: "Rate limit " + "reached. Try again later.", agent: .cursor))
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
        let claudeText = "Claude is currently unavailable."
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

    // MARK: - Prose must not trigger a limit

    /// Regression: the reset-phrase rule matched any text containing those words, so an agent
    /// merely *discussing* a limit — or linkC's own notice about one — was read as that agent
    /// being exhausted. linkC then cancelled its work and synthesized a task for a peer, which
    /// spent another agent's quota on work nobody asked for. Only an agent's own exhaustion
    /// banner may match.
    func testProseAboutALimitIsNotALimit() {
        let prose = [
            "Two hunters died on your session limit — it resets at 3am.",
            "The cooldown resets in 15 minutes, so we can retry after that.",
            "I logged the finding: the detector treats a reset phrase as exhaustion.",
            "Reading the docs on how quotas reset at midnight UTC."
        ]
        for text in prose {
            XCTAssertNil(
                LimitDetector.detectLimit(inOutput: text, agent: .claude),
                "Prose must not be read as exhaustion: \(text)"
            )
        }
    }

    /// The real banner still has to be caught, reset wording and all.
    func testActualExhaustionBannerIsStillDetected() {
        let banners = [
            "You've hit your session limit · resets 3am (America/Chicago)",
            "You've reached your usage limit. Visit your console to upgrade.",
            "Claude usage limit reached · resets at 4pm"
        ]
        for text in banners {
            XCTAssertNotNil(
                LimitDetector.detectLimit(inOutput: text, agent: .claude),
                "A real exhaustion banner must be detected: \(text)"
            )
        }
    }
}
