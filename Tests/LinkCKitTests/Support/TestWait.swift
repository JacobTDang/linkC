import Foundation

/// How many 20 ms polls a test waits for an event it does not control (a child process negotiating
/// paste, a task changing state, a file appearing) before giving up: 30 s. A wait ends the moment its
/// condition holds, so the limit costs nothing on a passing run; it is generous because on a loaded
/// machine — parallel test processes, a busy CI runner — a child can take seconds to reach the state
/// the test is waiting for, and a limit of two seconds turned that into a failure of the test rather
/// than a slow pass. A test that expects an event NOT to happen picks its own short limit instead.
enum TestWait {
    static let polls = 1500
}
