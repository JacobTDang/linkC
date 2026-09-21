import XCTest
@testable import LinkCKit

/// A clock the test releases by hand: each `sleep` waits until `release()` is called, in order.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    var waiting: Int { waiters.count }
}

@MainActor
final class FlashMessageTests: XCTestCase {
    private func settle(_ gate: Gate, waiting count: Int) async {
        for _ in 0..<200 where await gate.waiting < count { await Task.yield() }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testAMessageShowsThenClearsAfterItsDuration() async {
        let gate = Gate()
        let flash = FlashMessage(duration: .seconds(3), sleep: { _ in await gate.wait() })

        flash.show("Couldn't start the update")
        XCTAssertEqual(flash.text, "Couldn't start the update")

        await settle(gate, waiting: 1)
        await gate.release()
        await settleUntil { flash.text == nil }
        XCTAssertNil(flash.text)
    }

    func testAnEmptyOrBlankMessageShowsNothing() {
        let flash = FlashMessage(duration: .seconds(3), sleep: { _ in })
        for message in ["", "   ", "\n"] {
            flash.show(message)
            XCTAssertNil(flash.text, "message \(message.debugDescription)")
        }
    }

    func testANewerMessageIsNotClearedByTheOlderOnesClock() async {
        let gate = Gate()
        let flash = FlashMessage(duration: .seconds(3), sleep: { _ in await gate.wait() })

        flash.show("first")
        await settle(gate, waiting: 1)
        flash.show("second")
        await settle(gate, waiting: 2)

        await gate.release()   // the first message's clock runs out
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(flash.text, "second", "an older clock must not clear a newer message")

        await gate.release()   // the second message's clock runs out
        await settleUntil { flash.text == nil }
        XCTAssertNil(flash.text)
    }

    func testShowingNilClearsAtOnce() {
        let flash = FlashMessage(duration: .seconds(3), sleep: { _ in })
        flash.show("visible")
        flash.show(nil)
        XCTAssertNil(flash.text)
    }
}
