import Foundation

public struct QuitWarning: Sendable, Equatable {
    public let title: String
    public let message: String
}

/// The quit-confirmation copy. Sessions resume after relaunch; terminals come back as
/// relaunchable rows (a fresh shell in the same folder — scrollback is gone), and the copy
/// says exactly that. Exited terminals aren't counted (nothing left to kill). The
/// sessions-only strings are pinned by test to the pre-terminals dialog, byte for byte.
public enum QuitWarningBuilder {
    public static func build(sessionCount: Int, runningTerminalCount: Int) -> QuitWarning? {
        switch (sessionCount, runningTerminalCount) {
        case (0, 0):
            return nil

        case (let sessions, 0):
            let noun = sessions == 1 ? "session" : "sessions"
            return QuitWarning(
                title: "Quit linkC and end \(sessions) \(noun)?",
                message: "Quitting ends the Claude Code \(noun) running in linkC, "
                    + "but \(sessions == 1 ? "it'll" : "they'll") be offered for restore next launch."
            )

        case (0, let terminals):
            let noun = terminals == 1 ? "terminal" : "terminals"
            return QuitWarning(
                title: "Quit linkC and end \(terminals) \(noun)?",
                message: "Quitting ends the \(noun) running in linkC. "
                    + "\(terminals == 1 ? "It'll be" : "They'll be") offered for relaunch next launch, without scrollback."
            )

        case (let sessions, let terminals):
            let sessionNoun = sessions == 1 ? "session" : "sessions"
            let terminalNoun = terminals == 1 ? "terminal" : "terminals"
            return QuitWarning(
                title: "Quit linkC and end \(sessions) \(sessionNoun) and \(terminals) \(terminalNoun)?",
                message: "Quitting ends the Claude Code \(sessionNoun) and \(terminalNoun) running in linkC. "
                    + "\(sessions == 1 ? "The session" : "Sessions") will be offered for restore next launch, "
                    + "\(terminals == 1 ? "the terminal" : "terminals") for relaunch."
            )
        }
    }
}
