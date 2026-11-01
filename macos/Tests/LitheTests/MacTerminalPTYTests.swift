import Foundation
@testable import Lithe
import LitheTerminalModule
import Testing

/// Integration coverage for the owned PTY host introduced for SwiftTerm 2.x.
/// Input must reach the child from both the transport and the terminal's delegate path.
/// Raw output must still be mirrored to `onOutput`.
/// A restart must replace the child while the surface stays usable.
@MainActor
@Suite("Mac terminal PTY transport (integration)")
struct MacTerminalPTYTests {
    @Test
    func catEchoesInputAndForwardsRawOutput() async throws {
        let transport = MacTerminalTransport()
        defer { transport.stop() }

        var output = Data()
        transport.onOutput = { chunk in
            output.append(chunk)
        }
        var terminationCodes: [Int32?] = []
        transport.onTermination = { terminationCodes.append($0) }

        let directory = NSTemporaryDirectory()
        let launch = TerminalProcessLaunch(
            title: nil,
            executablePath: "/bin/cat",
            arguments: [],
            workingDirectory: directory,
        )
        let firstProcessID = try transport.startProcess(launch, environment: transport.defaultEnvironment())
        #expect(firstProcessID > 0)
        #expect(transport.isRunning)
        try transport.send(Data("lithe-pty-ok\n".utf8))
        let view = transport.view
        view.terminalDelegate?.send(source: view, data: ArraySlice("lithe-view-route-ok\n".utf8))

        let clock = ContinuousClock()
        func received(_ marker: String) -> Bool {
            String(decoding: output, as: UTF8.self).contains(marker)
        }
        let deadline = clock.now.advanced(by: .seconds(3))
        while !received("lithe-pty-ok") || !received("lithe-view-route-ok"), clock.now < deadline {
            await Task.yield()
        }

        #expect(received("lithe-pty-ok"), "PTY output missing transport marker: \(String(decoding: output, as: UTF8.self))")
        #expect(received("lithe-view-route-ok"), "PTY output missing view route marker: \(String(decoding: output, as: UTF8.self))")

        // Restarting the owned PTY must replace the child while the surface stays attached to the same transport.
        let secondProcessID = try transport.startProcess(launch, environment: transport.defaultEnvironment())
        #expect(secondProcessID > 0)
        #expect(secondProcessID != firstProcessID)
        #expect(transport.isRunning)
        try transport.send(Data("lithe-restart-ok\n".utf8))

        let restartDeadline = clock.now.advanced(by: .seconds(3))
        while !received("lithe-restart-ok"), clock.now < restartDeadline {
            await Task.yield()
        }
        #expect(received("lithe-restart-ok"), "PTY output missing restart marker: \(String(decoding: output, as: UTF8.self))")
        // The retired child's termination callback reaches the main queue only after the process is gone.
        // Bound the wait instead of assuming order.
        let retiredDeadline = clock.now.advanced(by: .seconds(3))
        while MacProcessTable.info(processID: firstProcessID) != nil, clock.now < retiredDeadline {
            await Task.yield()
        }
        await Task.yield()
        #expect(terminationCodes.isEmpty,
                "Restart must suppress the retired child's termination: \(terminationCodes)")
        await transport.stopAndWait()
    }
}
