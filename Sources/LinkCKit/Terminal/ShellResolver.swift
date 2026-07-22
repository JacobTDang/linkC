import Foundation

/// Resolves the user's login shell for dev terminals. Primary source is the passwd record
/// (`getpwuid`) — the same source Terminal.app uses, reliable regardless of launch context.
/// `$SHELL` is only a fallback: a Finder/login-item-launched GUI app inherits launchd's
/// minimal environment, which often lacks SHELL entirely (the same reason `TerminalSession`
/// patches PATH). Last resort is macOS's default, /bin/zsh.
public enum ShellResolver {
    public static func loginShell(
        passwdShell: () -> String? = systemPasswdShell,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(passwdShell: passwdShell(), environment: environment)
    }

    static func resolve(passwdShell: String?, environment: [String: String]) -> String {
        if let shell = passwdShell, !shell.isEmpty { return shell }
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// The classic Unix login-shell signal: argv[0] is the shell's basename prefixed with
    /// "-" ("-zsh"), which makes any shell source its login files — no per-shell flag games.
    public static func loginArgv0(for shellPath: String) -> String {
        "-" + (shellPath as NSString).lastPathComponent
    }

    /// Public only because a public function's default argument must reference a symbol at
    /// least as visible as itself.
    public static func systemPasswdShell() -> String? {
        guard let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell else {
            return nil
        }
        return String(cString: shell)
    }
}
