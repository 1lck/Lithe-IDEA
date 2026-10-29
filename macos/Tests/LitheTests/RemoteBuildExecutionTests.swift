import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Remote build execution")
struct RemoteBuildExecutionTests {
    private let root = URL(fileURLWithPath: "/fixture/build-placeholder")

    private func registry() -> RemoteWorkspaceRegistry {
        let registry = RemoteWorkspaceRegistry()
        registry.register(.init(root: root, remoteRoot: "/host/project", sessionID: "original", connectionID: UUID()))
        return registry
    }

    @Test
    func mapsOnlyTypedPathsAndCapturesStdoutSeparately() async throws {
        let host = BuildProcessFixture()
        let runner = MacRemoteBuildCommandRunner(local: NoLocalBuildRunner(), registry: registry(), host: host)
        let streamed = BuildOutputFixture()
        let opaque = "--message=\(root.path)/keep-this-literal"
        let result = try await runner.run(.init(executableURL: root.appendingPathComponent("tool"),
            arguments: [opaque], workingDirectory: root.appendingPathComponent("module"),
            environment: ["VALUE": root.path], capturesStandardOutput: true, timeout: .seconds(12))) {
            streamed.append($0)
        }
        #expect(host.calls.first?.0 == RemoteProcessRequest(argv: ["/host/project/tool", opaque],
            cwd: "/host/project/module", env: ["VALUE": root.path]))
        #expect(host.calls.first?.1 == "original")
        #expect(host.calls.first?.2 == .seconds(12))
        #expect(result.standardOutput == "model")
        #expect(streamed.value == "warning")
        #expect(result.termination == .exited(0))
    }

    @Test
    func interleavedStreamsKeepTheirOwnPartialUTF8Codepoints() async throws {
        let host = BuildProcessFixture()
        host.events = [
            .output(Data([0xe4, 0xb8]), standardError: false),
            .output(Data([0xe6, 0x96]), standardError: true),
            .output(Data([0xad]), standardError: false),
            .output(Data([0x87]), standardError: true)
        ]
        let runner = MacRemoteBuildCommandRunner(local: NoLocalBuildRunner(), registry: registry(), host: host)
        let streamed = BuildOutputFixture()
        _ = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/host/bin/build"),
            arguments: [], workingDirectory: root, environment: [:]), onOutput: { streamed.append($0) })
        #expect(streamed.value == "\u{4e2d}\u{6587}")
    }

    @Test
    func timeoutAndTransportFailureNeverRunLocally() async throws {
        let host = BuildProcessFixture()
        let runner = MacRemoteBuildCommandRunner(local: NoLocalBuildRunner(), registry: registry(), host: host)
        let request = BuildCommandRequest(executableURL: URL(fileURLWithPath: "/host/bin/build"),
            arguments: [], workingDirectory: root, environment: [:])
        host.failure = RemoteProbeFailure(code: "timed_out", message: "fixture")
        #expect(try await runner.run(request, onOutput: { _ in }).termination == .timedOut)
        host.failure = RemoteProbeFailure(code: "connection_closed", message: "fixture")
        await #expect(throws: RemoteProbeFailure.self) { try await runner.run(request, onOutput: { _ in }) }
    }

    @Test
    func rejectsCrossHostExecutableAndPreservesSignalFailure() async throws {
        let registry = registry()
        registry.register(.init(root: URL(fileURLWithPath: "/fixture/second"), remoteRoot: "/second",
                                sessionID: "second", connectionID: UUID()))
        let host = BuildProcessFixture()
        let runner = MacRemoteBuildCommandRunner(local: NoLocalBuildRunner(), registry: registry, host: host)
        let request = BuildCommandRequest(executableURL: URL(fileURLWithPath: "/fixture/second/tool"),
            arguments: [], workingDirectory: root, environment: [:])
        await #expect(throws: CocoaError.self) { try await runner.run(request, onOutput: { _ in }) }
        #expect(host.calls.isEmpty)
        host.result = .init(exitCode: nil, signal: 15)
        let signalled = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/host/bin/build"),
            arguments: [], workingDirectory: root, environment: [:]), onOutput: { _ in })
        #expect(signalled.termination == .exited(143))
    }

    @Test
    func statePreparationRunsOffMainAndCleanupRetainsOriginalSession() async throws {
        let registry = registry()
        let host = BuildStateFixture()
        let locator = MacRemoteBuildStateLocator(local: NoLocalBuildState(), registry: registry, host: host)
        let resources = try await locator.prepareRun(pluginID: "fixture", buildSystemID: "build",
            packageURL: URL(fileURLWithPath: "/local/plugin"), workspaceURL: root, allocatesOutputFile: true)
        #expect(resources.workspaceStateDirectory.path == "/host/state")
        #expect(resources.outputFile?.deletingLastPathComponent() == resources.workspaceStateDirectory)
        #expect(resources.pluginDirectory == nil)
        registry.register(.init(root: root, remoteRoot: "/host/project", sessionID: "replacement", connectionID: UUID()))
        await resources.release()
        #expect(host.preparedSession == "original")
        #expect(host.removedSession == "original")
        #expect(!host.usedMainThread)
    }
}

private struct NoLocalBuildRunner: BuildCommandRunning {
    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> BuildCommandResult {
        Issue.record("A remote build must never fall back to a local process")
        throw CocoaError(.featureUnsupported)
    }
}

private struct NoLocalBuildState: BuildSystemStateLocating {
    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL {
        Issue.record("Remote state must not be allocated locally")
        throw CocoaError(.featureUnsupported)
    }
    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
    func removeOutputFile(_ url: URL) { Issue.record("Remote output must not be removed locally") }
}

private final class BuildProcessFixture: RemoteProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(RemoteProcessRequest, String, Duration?)] = []
    var calls: [(RemoteProcessRequest, String, Duration?)] { lock.withLock { recorded } }
    // Each test mutates the scripted outcome only between awaited invocations.
    var failure: RemoteProbeFailure?
    var result = RemoteProcessResult(exitCode: 0, signal: nil)
    var events: [RemoteProcessEvent] = [.output(Data("model".utf8), standardError: false), .output(Data("warning".utf8), standardError: true)]
    func runProcess(_ request: RemoteProcessRequest, session: String, timeout: Duration?,
                    onEvent: @escaping @Sendable (RemoteProcessEvent) -> Void) async throws -> RemoteProcessResult {
        lock.withLock { recorded.append((request, session, timeout)) }
        if let failure { throw failure }
        events.forEach(onEvent)
        return result
    }
}

private final class BuildOutputFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ value: String) { lock.withLock { text += value } }
    var value: String { lock.withLock { text } }
}

private final class BuildStateFixture: RemoteBuildStateAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: String?
    private var removed: String?
    private var mainThread = false
    var preparedSession: String? { lock.withLock { prepared } }
    var removedSession: String? { lock.withLock { removed } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    func prepareBuildState(pluginID: String, buildSystemID: String, workspacePath: String, session: String) throws -> String {
        lock.withLock { prepared = session; mainThread = mainThread || Thread.isMainThread }
        #expect(workspacePath == "/host/project")
        return "/host/state"
    }
    func removeBuildOutputFile(_ path: String, session: String) throws {
        lock.withLock { removed = session; mainThread = mainThread || Thread.isMainThread }
        #expect(path.hasPrefix("/host/state/"))
    }
}
