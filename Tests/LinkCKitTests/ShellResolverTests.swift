import XCTest
@testable import LinkCKit

/// Login-shell resolution: passwd record first (what Terminal.app uses — a Finder-launched
/// app's environment often has no SHELL at all), then $SHELL, then /bin/zsh.
final class ShellResolverTests: XCTestCase {

    func testPasswdRecordWinsOverEnvironment() {
        XCTAssertEqual(
            ShellResolver.resolve(passwdShell: "/opt/homebrew/bin/fish", environment: ["SHELL": "/bin/bash"]),
            "/opt/homebrew/bin/fish"
        )
    }

    func testEnvironmentFallsBackWhenPasswdMissingOrEmpty() {
        XCTAssertEqual(ShellResolver.resolve(passwdShell: nil, environment: ["SHELL": "/bin/bash"]), "/bin/bash")
        XCTAssertEqual(ShellResolver.resolve(passwdShell: "", environment: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    func testDefaultsToZshWhenNothingResolves() {
        XCTAssertEqual(ShellResolver.resolve(passwdShell: nil, environment: [:]), "/bin/zsh")
        XCTAssertEqual(ShellResolver.resolve(passwdShell: "", environment: ["SHELL": ""]), "/bin/zsh")
    }

    func testLoginArgv0PrefixesDashOnBasename() {
        XCTAssertEqual(ShellResolver.loginArgv0(for: "/bin/zsh"), "-zsh")
        XCTAssertEqual(ShellResolver.loginArgv0(for: "/opt/homebrew/bin/fish"), "-fish")
    }
}
