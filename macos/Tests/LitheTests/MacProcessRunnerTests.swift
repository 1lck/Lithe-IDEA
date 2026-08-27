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

        #expect(throws: (any Error).self) {
            try session.start(terminationResistantRequest(operationID: "raw-timeout"))
        }

        #expect(await terminated.waitUntilOpen())
        #expect(!session.isRunning)
    }

    @Test
    func streamingSessionTimeoutUnblocksInitialInputAndForceTerminates() async {
        let session = MacStreamingProcess()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        #expect(throws: (any Error).self) {
            try session.start(terminationResistantRequest(operationID: "streaming-timeout"))
        }

        #expect(await terminated.waitUntilOpen())
        #expect(!session.isRunning)
    }

    @Test
    func timeoutTerminatesDescendantThatClosesPipesAndIgnoresTermination() throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }

        let result = MacProcessRunner().run(fixture.request(operationID: "runner-tree"))

        #expect(result.exitCode == 124)
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(waitUntilProcessExitsSynchronously(descendantPID))
    }

    @Test
    func rawSessionTimeoutTerminatesDescendantThatClosesPipesAndIgnoresTermination() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }
        let session = MacRawProcessSession()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        try session.start(fixture.request(operationID: "raw-tree"))

        #expect(await terminated.waitUntilOpen())
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(await waitUntilProcessExits(descendantPID))
    }

    @Test
    func streamingSessionTimeoutTerminatesDescendantThatClosesPipesAndIgnoresTermination() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }
        let session = MacStreamingProcess()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        try session.start(fixture.request(operationID: "streaming-tree"))

        #expect(await terminated.waitUntilOpen())
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(await waitUntilProcessExits(descendantPID))
    }

    @Test
    func streamingStopAndWaitConfirmsDescendantTreeExited() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }
        let session = MacStreamingProcess()
        let ready = TestGate()
        session.onOutput = { output in
            if output.contains("ready") { ready.open() }
        }
        defer { session.stop() }

        try session.start(fixture.request(operationID: "streaming-stop", timeoutMilliseconds: nil))
        #expect(await ready.waitUntilOpen())
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }

        #expect(await session.stopAndWait())
        #expect(!processIsRunning(descendantPID))
    }

    @Test
    func testProcessTimeoutTerminatesDescendantThatClosesPipesAndIgnoresTermination() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }

        await #expect(throws: TestProcessError.self) {
            try await TestProcess.run(
                executableURL: URL(fileURLWithPath: fixture.request(operationID: nil).executablePath),
                arguments: fixture.request(operationID: nil).arguments,
                currentDirectoryURL: fixture.directory,
                timeout: .milliseconds(300)
            )
        }

        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(await waitUntilProcessExits(descendantPID))
    }

    @Test
    func normalExitTerminatesBackgroundDescendantThatRetainsPipes() throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }

        let result = MacProcessRunner().run(
            fixture.normalExitRequest(operationID: "runner-normal-exit")
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("ready"))
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(!processIsRunning(descendantPID))
    }

    @Test
    func rawSessionNormalExitTerminatesBackgroundDescendantThatRetainsPipes() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }
        let session = MacRawProcessSession()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        try session.start(fixture.normalExitRequest(operationID: "raw-normal-exit"))

        #expect(await terminated.waitUntilOpen())
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(!processIsRunning(descendantPID))
    }

    @Test
    func streamingSessionNormalExitTerminatesBackgroundDescendantThatRetainsPipes() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }
        let session = MacStreamingProcess()
        let terminated = TestGate()
        session.onTermination = { _ in terminated.open() }
        defer { session.stop() }

        try session.start(fixture.normalExitRequest(operationID: "streaming-normal-exit"))

        #expect(await terminated.waitUntilOpen())
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(!processIsRunning(descendantPID))
    }

    @Test
    func testProcessNormalExitTerminatesBackgroundDescendantThatRetainsPipes() async throws {
        let fixture = try makeDescendantFixture()
        defer { fixture.cleanup() }
        let request = fixture.normalExitRequest(operationID: nil)

        let result = try await TestProcess.run(
            executableURL: URL(fileURLWithPath: request.executablePath),
            arguments: request.arguments,
            currentDirectoryURL: fixture.directory
        )

        #expect(result.terminationStatus == 0)
        #expect(String(decoding: result.output, as: UTF8.self).contains("ready"))
        let descendantPID = try fixture.descendantPID()
        defer { terminateIfRunning(descendantPID) }
        #expect(!processIsRunning(descendantPID))
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

    private func makeDescendantFixture() throws -> DescendantFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-process-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DescendantFixture(directory: directory)
    }

    private func waitUntilProcessExitsSynchronously(
        _ pid: pid_t,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while processIsRunning(pid), Date() < deadline {
            // test-stability: allow(swift-real-sleep) reason: synchronous runner verification must poll bounded OS process liveness.
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !processIsRunning(pid)
    }

    private func waitUntilProcessExits(
        _ pid: pid_t,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while processIsRunning(pid), clock.now < deadline {
            // test-stability: allow(swift-real-sleep) reason: orphan process liveness has no callback, so bounded OS polling is required to verify cleanup.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !processIsRunning(pid)
    }

    private func processIsRunning(_ pid: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func terminateIfRunning(_ pid: pid_t) {
        if processIsRunning(pid) {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

private struct DescendantFixture {
    let directory: URL

    private var pidFile: URL {
        directory.appendingPathComponent("descendant.pid")
    }

    func request(operationID: String?, timeoutMilliseconds: Int? = 300) -> ProcessRequest {
        ProcessRequest(
            operationID: operationID,
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                """
                /bin/sh -c 'trap "" TERM; exec >/dev/null 2>&1; while :; do :; done' &
                child=$!
                printf '%s' "$child" > "$1"
                printf 'ready\n'
                wait "$child"
                """,
                "lithe-process-tree",
                pidFile.path
            ],
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    func normalExitRequest(operationID: String?) -> ProcessRequest {
        ProcessRequest(
            operationID: operationID,
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                """
                /bin/sh -c 'trap "" TERM HUP; while :; do :; done' &
                child=$!
                printf '%s' "$child" > "$1"
                printf 'ready\n'
                exit 0
                """,
                "lithe-process-group",
                pidFile.path
            ]
        )
    }

    func descendantPID() throws -> pid_t {
        let contents = try String(contentsOf: pidFile, encoding: .utf8)
        return try #require(pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
