import AppKit
import Foundation
import LinkCKit

let parsed: LinkCCommand.Parsed
do {
    parsed = try LinkCCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("linkc: \(error)\n\n\(LinkCCommand.usage)\n".utf8))
    exit(2)
}
guard case .open(let invocation) = parsed else {
    print(LinkCCommand.usage)
    exit(0)
}

let bundleIdentifier = "com.linkc.app"
let environment = LinkCCommand.Environment(
    store: .applicationSupport,
    folder: FileManager.default.currentDirectoryPath,
    caller: {
        // The agent this command runs under: its parent, or an ancestor above the shell an agent's tool starts.
        guard let found = ProcessSnooper.detectAgent(inAncestorsOf: getpid()) else { return nil }
        return (found.agent, ProcessInfo.processInfo.environment["LINKC_SESSION"])
    },
    isLinkCRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty },
    launchLinkC: {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleIdentifier]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw LinkCCommand.LaunchError(status: open.terminationStatus) }
    },
    now: Date.init,
    sleep: { Thread.sleep(forTimeInterval: $0) }
)
let outcome = LinkCCommand.run(invocation, in: environment)
let output = outcome.status == 0 ? FileHandle.standardOutput : FileHandle.standardError
output.write(Data((outcome.output + "\n").utf8))
exit(outcome.status)
