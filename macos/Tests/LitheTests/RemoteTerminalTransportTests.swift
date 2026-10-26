import Foundation
import LitheTerminalModule
import SwiftTerm
import Testing
@testable import Lithe

@Suite("Remote terminal transport") @MainActor
struct RemoteTerminalTransportTests {
    private let root = URL(fileURLWithPath: "/fixture/placeholder")

    private func terminal(_ host: FixtureTerminalHost) -> (MacRemoteTerminalTransport, MacTerminalTransport) {
        let renderer = MacTerminalTransport(scrollbackLines: 100)
        let binding = RemoteWorkspaceBinding(root: root, remoteRoot: "/host/project",
                                             sessionID: "host-one", connectionID: UUID())
        return (MacRemoteTerminalTransport(renderer: renderer, binding: binding, transport: host), renderer)
    }

    @Test
    func managedLaunchUsesTheWorkspaceHostAndKeepsArgumentsSeparate() async throws {
        let host = FixtureTerminalHost()
        let (transport, renderer) = terminal(host)
        defer { transport.stop(); host.finish() }
        let launch = TerminalProcessLaunch(title: "Run", executablePath: "/host/jdk/bin/java",
            arguments: ["-cp", "/host/project/classes with spaces", "Main"],
            workingDirectory: root.appendingPathComponent("module").path)
        let pid = try await transport.startProcessAsync(launch, environment: ["TERM": "xterm-256color"])
        #expect(pid == 321)
        #expect(renderer.view.process?.running != true)
        #expect(renderer.view.hasRemoteProcess)
        #expect(host.requests.first?.session == "host-one")
        #expect(host.requests.first?.request.cwd == "/host/project/module")
        #expect(host.requests.first?.request.argv == ["/host/jdk/bin/java", "-cp", "/host/project/classes with spaces", "Main"])
        try transport.send(Data("input\n".utf8))
        #expect(await terminalEventually { !host.writes.isEmpty })
        #expect(host.writes.first == Data("input\n".utf8))
        await transport.stopAndWait()
        #expect(host.activeRuns == 0)
        #expect(!renderer.view.hasRemoteProcess)
    }

    @Test
    func shellUsesRemoteDefaultAndCoalescesResizeWhileControlIsPending() async throws {
        let host = FixtureTerminalHost(holdsWrites: true)
        let (transport, renderer) = terminal(host)
        defer { transport.stop(); host.finish() }
        try await transport.startShell(workingDirectory: root.path, shellPath: transport.defaultShellPath(), environment: [:])
        #expect(host.requests.first?.request.argv == nil)
        #expect(host.requests.first?.request.cwd == "/host/project")
        try transport.send(Data([1]))
        #expect(await terminalEventually { !host.writes.isEmpty })
        let previous = host.sizes.count
        for column in 40...140 {
            renderer.view.terminalDelegate?.sizeChanged(source: renderer.view, newCols: column, newRows: 50)
        }
        #expect(host.sizes.count == previous)
        host.releaseWrite()
        #expect(await terminalEventually { host.sizes.count > previous })
        #expect(host.sizes.count == previous + 1)
        #expect(host.sizes.last?.columns == 140)
        #expect(host.sizes.last?.rows == 50)
        await transport.stopAndWait()
        #expect(host.activeRuns == 0)
    }

    @Test
    func stoppingBeforeAcknowledgementDoesNotPublishTheManagedSession() async throws {
        let host = FixtureTerminalHost(acknowledgesStart: false)
        let (transport, _) = terminal(host)
        let feature = TerminalFeatureModel(terminalFactory: { transport }, workspaceTerminalFactory: { _ in transport })
        defer { feature.stopAllSessions(); host.finish() }
        let started = Task { @MainActor in
            try await feature.createProcessSessionAsync(
                TerminalProcessLaunch(title: nil, executablePath: "/host/bin/tool", arguments: [], workingDirectory: "/host/project"),
                workspaceURL: root)
        }
        #expect(await terminalEventually { host.activeRuns == 1 })
        #expect(feature.hasActiveSessions)
        await feature.stopAllSessionsAndWait()
        do {
            _ = try await started.value
            Issue.record("A stopped launch must not publish a terminal")
        } catch is CancellationError {} catch { Issue.record("Unexpected launch failure: \(error)") }
        #expect(feature.terminalSessions.isEmpty)
        #expect(!feature.hasActiveSessions)
        #expect(host.activeRuns == 0)
    }

    @Test
    func exitedTerminalReleasesItsRemoteSurfaceAndNotifiesOnce() async throws {
        let host = FixtureTerminalHost()
        let (transport, renderer) = terminal(host)
        defer { transport.stop(); host.finish() }
        var exits: [Int32?] = []
        transport.onTermination = { exits.append($0) }
        try await transport.startShell(workingDirectory: root.path, shellPath: "/host/bin/fish", environment: [:])
        #expect(host.requests.first?.request.argv == ["/host/bin/fish", "-l", "-i"])
        host.finish(exit: 7)
        #expect(await terminalEventually { host.activeRuns == 0 })
        #expect(!transport.isRunning)
        #expect(transport.processID == nil)
        #expect(!renderer.view.hasRemoteProcess)
        #expect(exits.count == 1)
        #expect(exits.first == 7)
        await transport.stopAndWait()
        #expect(exits.count == 1)
    }

    @Test
    func endedConnectionReleasesTerminalIdentityWithoutAnExitEvent() async throws {
        let host = FixtureTerminalHost(holdsWrites: true)
        let (transport, renderer) = terminal(host)
        defer { transport.stop(); host.finish() }
        var exits: [Int32?] = []
        transport.onTermination = { exits.append($0) }
        try await transport.startShell(workingDirectory: root.path, shellPath: transport.defaultShellPath(), environment: [:])
        try transport.send(Data([1]))
        #expect(await terminalEventually { !host.writes.isEmpty })

        // The connection finishes without terminal.exit while an input control
        // is pending. Neither its PID nor that control may survive teardown.
        host.finish()
        #expect(await terminalEventually { exits.count == 1 })
        #expect(exits.first == .some(nil))
        #expect(!transport.isRunning)
        #expect(transport.processID == nil)
        #expect(!renderer.view.hasRemoteProcess)
        await transport.stopAndWait()
        #expect(host.activeRuns == 0)
        #expect(exits.count == 1)
    }
}

@MainActor
private func terminalEventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private final class FixtureTerminalHost: RemoteTerminalConnecting, @unchecked Sendable {
    struct Request { let session: String; let request: RemoteTerminalRequest }
    struct Size { let columns: UInt16; let rows: UInt16 }
    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var recordedWrites: [Data] = []
    private var recordedSizes: [Size] = []
    private var runs = 0
    private var observer: (@Sendable (RemoteTerminalEvent) -> Void)?
    private var end: AsyncStream<Void>.Continuation?
    private let writeStream: AsyncStream<Void>
    private let writeContinuation: AsyncStream<Void>.Continuation
    let acknowledgesStart: Bool
    let holdsWrites: Bool
    var requests: [Request] { lock.withLock { recordedRequests } }
    var writes: [Data] { lock.withLock { recordedWrites } }
    var sizes: [Size] { lock.withLock { recordedSizes } }
    var activeRuns: Int { lock.withLock { runs } }

    init(acknowledgesStart: Bool = true, holdsWrites: Bool = false) {
        self.acknowledgesStart = acknowledgesStart
        self.holdsWrites = holdsWrites
        (writeStream, writeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func runTerminal(_ request: RemoteTerminalRequest, session: String,
                     onEvent: @escaping @Sendable (RemoteTerminalEvent) -> Void) async -> Result<Void, RemoteProbeFailure> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            recordedRequests.append(Request(session: session, request: request))
            runs += 1
            observer = onEvent
            end = continuation
        }
        defer { lock.withLock { runs -= 1; observer = nil; end = nil } }
        if acknowledgesStart { onEvent(.started(id: 17, pid: 321)) }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        return .success(())
    }
    func writeTerminal(_ data: Data, id: UInt64, session: String) async throws {
        #expect(id == 17 && session == "host-one")
        lock.withLock { recordedWrites.append(data) }
        if holdsWrites {
            var iterator = writeStream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
    func resizeTerminal(id: UInt64, columns: UInt16, rows: UInt16, session: String) async throws {
        #expect(id == 17 && session == "host-one")
        lock.withLock { recordedSizes.append(Size(columns: columns, rows: rows)) }
    }
    func releaseWrite() { writeContinuation.yield() }
    func finish(exit: Int32? = nil) {
        let (observer, continuation) = lock.withLock { (observer, end) }
        if let exit { observer?(.exited(exit)) }
        continuation?.finish()
        writeContinuation.finish()
    }
}
