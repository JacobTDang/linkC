import Foundation

/// Reads a Supabase project's live schema through the user's own `supabase` CLI. linkC never
/// holds database credentials — `supabase login` keeps its token in the Keychain, and this always
/// runs through the user's own login shell, exactly as `VerificationRunner` runs a task's test
/// command, so it sees the PATH and dotfiles a terminal would, not launchd's minimal one.
public enum SupabaseSchemaDump {
    /// How long `supabase db dump` gets before it's killed — a cold or large project can take a
    /// while to answer, but a stalled dump must not hang the app forever.
    private static let timeout: TimeInterval = 120
    private static let command = "supabase db dump"

    /// Runs `supabase db dump` in `projectPath` and returns stdout. A nonzero exit
    /// throws `LinkCError.process` with the last 5 lines of stderr (this is also what a missing
    /// `supabase` CLI looks like: the shell's own "command not found" on stderr, exit 127); a
    /// timeout throws `LinkCError.process` naming the timeout.
    public static func run(projectPath: String, runner: ProcessRunner) async throws -> String {
        let shell = ShellResolver.loginShell()
        let cwd = URL(fileURLWithPath: projectPath)
        let result: ProcessResult
        do {
            result = try await runner.runCapturing(shell, args: ["-l", "-c", command], cwd: cwd, timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("\(command) timed out after \(seconds)s")
        }
        guard result.status == 0 else {
            throw LinkCError.process(failureMessage(status: result.status, stderr: result.stderr))
        }
        return result.stdout
    }

    /// The last 5 non-empty, trimmed lines of stderr, newline-joined — enough of a `supabase`
    /// failure to act on without a whole banner. Falls back to naming the exit status alone when
    /// stderr is empty, so the thrown message is never blank.
    private static func failureMessage(status: Int32, stderr: String) -> String {
        let lines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "\(command) exited with status \(status)" }
        return lines.suffix(5).joined(separator: "\n")
    }
}
