import Foundation
import LitheGitModule
import LitheModuleAPI
import Testing
@testable import Lithe

private final class CoreTraceBundleMarker: NSObject {}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var lines: [String] { lock.withLock { values } }
    func append(_ lines: [String]) -> [String] { lock.withLock { values += lines; return values } }
}

@Suite("Core request and Git process traces")
struct CoreRequestTraceTests {
    @Test
    func userGitCommandReachesTheLogUnderItsActionAndBackgroundReadsWaitForDiagnostics() async throws {
        // Core's trace queue and DEBUG gate belong to the process. Run this real
        // Core-to-file boundary alone so other stores cannot drain or reconfigure it.
        if ProcessInfo.processInfo.environment["LITHE_CORE_TRACE_CHILD"] != "1" {
            let image = try #require(Bundle(for: CoreTraceBundleMarker.self).executableURL)
            var environment = ProcessInfo.processInfo.environment
            environment["LITHE_CORE_TRACE_CHILD"] = "1"
            let result = try await TestProcess.run(
                executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: ["--test-bundle-path", image.path, "--testing-library", "swift-testing", "--filter",
                    "LitheTests.CoreRequestTraceTests/userGitCommandReachesTheLogUnderItsActionAndBackgroundReadsWaitForDiagnostics"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: environment, timeout: .seconds(20))
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(result.terminationStatus == 0, "Isolated Core trace failed: \(output)")
            #expect(output.contains("Test run with 1 test in 1 suite passed"))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = RustCoreBridge()
        for arguments in [["init", "-q"], ["config", "user.name", "Trace Test"],
            ["config", "user.email", "trace@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            #expect(core.gitCommand(at: repository, arguments: arguments)?.exitCode == 0)
        }

        let writer = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"))
        RustCoreBridge.onCoreEventsPending = { [weak writer] in writer?.scheduleCoreDrain() }
        defer { RustCoreBridge.onCoreEventsPending = nil }
        let stream = try await writer.subscribe()
        let buffer = LineBuffer()
        let traced = TestGate()
        let consumer = Task {
            for await batch in stream {
                let lines = buffer.append(batch.map(\.line))
                if lines.contains(where: { $0.contains("event=vcs.git.command.finished") }),
                   lines.contains(where: { $0.contains("event=app.core.request.finished") }) {
                    traced.open()
                    break
                }
            }
        }
        defer { consumer.cancel() }

        // No flush: Core's pending flag alone must schedule the drain.
        let action = try #require(UserActionTrace.run("vcs.commit", surface: .button, sink: writer) { () -> UserAction? in
            #expect(core.gitCommand(at: repository, arguments: ["commit", "--allow-empty", "-m", "secret subject"])?.exitCode == 0)
            return UserActionContext.current
        })
        #expect(await traced.waitUntilOpen(timeout: .seconds(5)))
        let lines = buffer.lines
        let operation = "op=\(action.operationID)"
        #expect(lines.contains { $0.contains("event=app.action.performed") && $0.contains(operation) })
        let git = lines.first { $0.contains("event=vcs.git.command.finished") }
        #expect(git?.contains(operation) == true)
        #expect(git?.contains("-m <message>") == true)
        let request = lines.first { $0.contains("event=app.core.request.finished") }
        #expect(request?.contains(operation) == true)
        #expect(request?.contains("trigger=vcs.commit") == true)
        #expect(!lines.contains { $0.contains("secret") })

        _ = GitExecutionSource.$current.withValue(.background) { core.gitStatus(at: repository) }
        try await writer.flush()
        let gated = try await writer.collect(query: .init(session: "all"))
        #expect(!gated.content.contains("event=vcs.git.command.traced"))

        await writer.configureDiagnostic(category: "git", enabled: true)
        _ = GitExecutionSource.$current.withValue(.background) { core.gitStatus(at: repository) }
        try await writer.flush()
        let enabled = try await writer.collect(query: .init(session: "all"))
        #expect(enabled.content.contains("event=vcs.git.command.traced"))
        await writer.configureDiagnostic(category: "git", enabled: false)
        await writer.finishSession()
    }
}
