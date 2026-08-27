import Darwin
import Foundation
import Testing
@testable import Lithe

@Suite("macOS process runner")
struct MacProcessRunnerTests {
    @Test
    func timeoutForceTerminatesAProcessThatIgnoresTermination() throws {
        let shellURL = URL(fileURLWithPath: "/bin/sh")
        guard FileManager.default.isExecutableFile(atPath: shellURL.path) else { return }

        let start = ContinuousClock.now
        let result = MacProcessRunner().run(ProcessRequest(
            executablePath: shellURL.path,
            arguments: ["-c", "trap '' TERM; echo $$; while :; do :; done"],
            standardInput: Data(repeating: 0x41, count: 1_048_576),
            timeoutMilliseconds: 100
        ))

        #expect(result.exitCode == 124)
        #expect(ContinuousClock.now - start < .seconds(2))
        let pid = try #require(Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test
    func rawSessionTimeoutUnblocksInitialInputAndForceTerminates() async {
        let session = MacRawProcessSession()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        let start = ContinuousClock.now
        #expect(throws: (any Error).self) {
            try session.start(terminationResistantRequest(operationID: "raw-timeout"))
        }

        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await terminated.waitUntilOpen())
        #expect(!session.isRunning)
    }

    @Test
    func streamingSessionTimeoutUnblocksInitialInputAndForceTerminates() async {
        let session = MacStreamingProcess()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        let start = ContinuousClock.now
        #expect(throws: (any Error).self) {
            try session.start(terminationResistantRequest(operationID: "streaming-timeout"))
        }

        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await terminated.waitUntilOpen())
        #expect(!session.isRunning)
    }

    private func terminationResistantRequest(operationID: String) -> ProcessRequest {
        ProcessRequest(
            operationID: operationID,
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            standardInput: Data(repeating: 0x41, count: 1_048_576),
            timeoutMilliseconds: 100
        )
    }
}
