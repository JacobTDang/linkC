import XCTest
@testable import LinkCKit

final class CacheClockTests: XCTestCase {
    private let turnEnded = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ agent: AgentKind, model: String?, state: SessionState = .finished) -> Session {
        Session(id: "S", cwd: "/tmp", title: "t", state: state, stateChangedAt: turnEnded, agentKind: agent, model: model)
    }

    func testAnExpiryTheAgentReportsIsExact() {
        let reported = Date(timeIntervalSince1970: 1_790_003_600)
        XCTAssertEqual(CacheClock.expiry(for: session(.claude, model: nil), reported: reported),
                       CacheExpiry(at: reported, isEstimate: false))
    }

    /// GPT-5.5 supports only 24-hour retention.
    func testCodexOnGPT55StaysWarmForADayAfterItsTurn() {
        XCTAssertEqual(CacheClock.expiry(for: session(.codex, model: "gpt-5.5-codex"), reported: nil),
                       CacheExpiry(at: turnEnded.addingTimeInterval(24 * 3600), isEstimate: true))
    }

    /// Other OpenAI models keep an in-memory cache for 5 to 10 idle minutes: the clock counts the shorter.
    func testCodexOnAnotherModelGoesColdFiveMinutesAfterItsTurn() {
        XCTAssertEqual(CacheClock.expiry(for: session(.codex, model: "gpt-5.4"), reported: nil),
                       CacheExpiry(at: turnEnded.addingTimeInterval(5 * 60), isEstimate: true))
    }

    func testNoClockWithoutAModelWhileWorkingOrForAnAgentWhoseCacheLifetimeIsUnknown() {
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: nil), reported: nil))
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: "gpt-5.5", state: .working), reported: nil))
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: "gpt-5.5", state: .starting), reported: nil))
        for agent in [AgentKind.agy, .cursor, .opencode, .kilo, .crush, .grok] {
            XCTAssertNil(CacheClock.expiry(for: session(agent, model: "some-model"), reported: nil), "\(agent)")
        }
    }
}
