import XCTest
@testable import LinkCKit

final class CacheClockTests: XCTestCase {
    private let turnEnded = Date(timeIntervalSince1970: 1_790_000_000)
    /// Later than the turn's end: focusing a finished tab, a recovered error, a dismissed prompt.
    private let flipped = Date(timeIntervalSince1970: 1_790_001_800)

    private func session(_ agent: AgentKind, model: String?, state: SessionState = .finished,
                         turnEndedAt: Date?? = .none) -> Session {
        Session(id: "S", cwd: "/tmp", title: "t", state: state, stateChangedAt: flipped,
                turnEndedAt: turnEndedAt ?? turnEnded, agentKind: agent, model: model)
    }

    func testAnExpiryTheAgentReportsIsExact() {
        let reported = Date(timeIntervalSince1970: 1_790_003_600)
        XCTAssertEqual(CacheClock.expiry(for: session(.claude, model: nil), reported: reported),
                       CacheExpiry(at: reported, isEstimate: false))
    }

    /// GPT-5.6 and later keep a cached prefix for at least 30 minutes by default; GPT-5.5's only
    /// retention typically keeps it about as long.
    func testCodexOnTheModelsLinkCLaunchesGoesColdHalfAnHourAfterItsTurn() {
        for model in ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-6-astra", "gpt-6.2-sol", "gpt-5.5", "gpt-5.5-pro"] {
            XCTAssertEqual(CacheClock.expiry(for: session(.codex, model: model), reported: nil),
                           CacheExpiry(at: turnEnded.addingTimeInterval(30 * 60), isEstimate: true), model)
        }
    }

    /// Earlier OpenAI models keep an in-memory cache for 5 to 10 idle minutes: the clock counts the shorter.
    func testCodexOnAnEarlierModelGoesColdFiveMinutesAfterItsTurn() {
        for model in ["gpt-5.4", "gpt-5.1-codex", "gpt-5", "gpt-4.1"] {
            XCTAssertEqual(CacheClock.expiry(for: session(.codex, model: model), reported: nil),
                           CacheExpiry(at: turnEnded.addingTimeInterval(5 * 60), isEstimate: true), model)
        }
    }

    /// The clock runs from the turn's last request, whatever the state flipped to since.
    func testEveryIdleStateCountsFromTheTurnsEndNotTheLastStateChange() {
        for state in [SessionState.finished, .ready, .waitingPermission, .waitingIdle, .error] {
            XCTAssertEqual(CacheClock.expiry(for: session(.codex, model: "gpt-5.6-sol", state: state), reported: nil)?.at,
                           turnEnded.addingTimeInterval(30 * 60), "\(state)")
        }
    }

    func testNoClockBeforeATurnHasRun() {
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: "gpt-5.6-sol", state: .ready, turnEndedAt: .some(nil)),
                                       reported: nil))
    }

    func testNoClockWithoutAModelWhileWorkingOrForAnAgentWhoseCacheLifetimeIsUnknown() {
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: nil), reported: nil))
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: "gpt-5.6-sol", state: .working), reported: nil))
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: "gpt-5.6-sol", state: .starting), reported: nil))
        XCTAssertNil(CacheClock.expiry(for: session(.codex, model: "not-a-gpt", state: .finished), reported: nil))
        for agent in [AgentKind.agy, .cursor, .opencode, .kilo, .crush, .grok] {
            XCTAssertNil(CacheClock.expiry(for: session(agent, model: "some-model"), reported: nil), "\(agent)")
        }
    }
}
