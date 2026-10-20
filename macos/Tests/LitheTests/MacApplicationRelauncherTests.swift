import Foundation
import Testing
@testable import Lithe

/// "Restart Lithe" hands the relaunch to a helper that outlives this process.
/// Only the command is checked here; running it would start another Lithe.
@Suite("Application relauncher")
struct MacApplicationRelauncherTests {
    @Test
    func bundledAppIsOpenedAgainAfterTheProcessExits() throws {
        let command = try #require(MacApplicationRelauncher.command(
            bundleURL: URL(fileURLWithPath: "/Applications/Lithe Preview.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Lithe Preview.app/Contents/MacOS/Lithe"),
            processID: 4242
        ))

        #expect(command.executableURL.path == "/bin/sh")
        // Paths are passed as arguments, never spliced into the script.
        #expect(Array(command.arguments.dropFirst(2)) == [
            "lithe-relaunch", "4242", "/Applications/Lithe Preview.app", "bundle",
            "\(MacApplicationRelauncher.exitWaitTenths)",
        ])
        let script = command.arguments[1]
        #expect(!script.contains("Lithe Preview"))
        // The wait is bounded, and a still-running old instance is only
        // activated by `open` rather than duplicated with `open -n`.
        #expect(script.contains("[ \"$i\" -lt \"$limit\" ]"))
        #expect(script.contains("exec /usr/bin/open \"$target\""))
        #expect(!script.contains("open -n"))
    }

    @Test
    func unbundledDevelopmentBuildStartsItsExecutable() throws {
        let command = try #require(MacApplicationRelauncher.command(
            bundleURL: URL(fileURLWithPath: "/tmp/build/debug"),
            executableURL: URL(fileURLWithPath: "/tmp/build/debug/Lithe"),
            processID: 7
        ))

        #expect(Array(command.arguments.suffix(3)) == ["/tmp/build/debug/Lithe", "executable", "\(MacApplicationRelauncher.exitWaitTenths)"])
    }

    @Test
    func nothingToRelaunchWithoutAnExecutable() {
        #expect(MacApplicationRelauncher.command(
            bundleURL: URL(fileURLWithPath: "/tmp/build/debug"),
            executableURL: nil,
            processID: 7
        ) == nil)
    }
}
