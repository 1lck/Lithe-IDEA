import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Remote runtime discovery")
struct RemoteRuntimeDiscoveryTests {
    private static let binding = RemoteWorkspaceBinding(
        root: URL(fileURLWithPath: "/fixture/remote-placeholder"), remoteRoot: "/host/project",
        sessionID: "fixture-host", connectionID: UUID()
    )

    @Test
    func discoversHostToolsAndNormalizesOnlyAgainstRemoteHome() {
        let host = FixtureRuntimeHost()
        let locator = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        locator.probeHost(isCancelled: { false })
        #expect(locator.discoveryFailure == nil)
        #expect(locator.environment()["HOME"] == "/host/home")
        #expect(locator.normalizedPath("~/tools", relativeTo: Self.binding.root) == "/host/home/tools")
        #expect(locator.normalizedPath("tools/tool-b", relativeTo: Self.binding.root) == "/host/project/tools/tool-b")
        #expect(locator.normalizedPath(Self.binding.root.path + "/run.sh", relativeTo: nil) == "/host/project/run.sh")
        #expect(locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/tool-a")))
        #expect(locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/tool-b")))
        #expect(!locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/not-executable")))
        #expect(!locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/not-executable-link")))
        #expect(locator.candidates(for: "tool-b", projectURL: Self.binding.root, environment: ["PATH": "/host/bin"])
            .map(\.executableURL.path) == ["/host/bin/tool-b"])
        let calls = host.callCount
        #expect(locator.candidates(for: "tool-a", projectURL: nil, environment: ["PATH": "/host/bin"]).count == 1)
        #expect(host.callCount == calls)
    }

    @Test
    func failedAndCancelledDiscoveryCannotPublishPartialOrLocalTools() {
        let host = FixtureRuntimeHost(failsEnvironment: true)
        let locator = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        locator.probeHost(isCancelled: { false })
        #expect(locator.discoveryFailure != nil)
        #expect(locator.environment().isEmpty)
        #expect(locator.candidates(for: "tool-b", projectURL: Self.binding.root, environment: ["PATH": "/host/bin"]).isEmpty)
        let calls = host.callCount
        locator.probeHost(isCancelled: { true })
        #expect(host.callCount == calls)
    }

    @Test
    func invalidatedProbeCannotOverwriteANewerSnapshot() {
        let host = FixtureRuntimeHost()
        let locator = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        host.beforeEnvironment = { locator.invalidateProbeCache() }
        locator.probeHost(isCancelled: { false })
        #expect(locator.environment().isEmpty)
        #expect(!locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/tool-b")))
        host.beforeEnvironment = nil
        locator.probeHost(isCancelled: { false })
        #expect(locator.environment()["HOME"] == "/host/home")
    }

    @Test @MainActor
    func projectSwitchUsesHostWorkersAndLocalProjectsKeepLocalDiscovery() async {
        let host = FixtureRuntimeHost()
        let remote = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        let local = FixtureLocalRuntimeLocator()
        let service = ProjectRuntimeService(runtimeLocator: local,
            workspaceRuntime: { $0 == Self.binding.root ? (remote, remote) : nil })
        defer { service.closeProject() }
        service.openProject(at: Self.binding.root)
        await service.ensureRuntimesDiscovered()
        #expect(service.executableCandidates("tool-b").map(\.executableURL.path) == ["/host/bin/tool-b"])
        #expect(service.processEnvironment()["HOME"] == "/host/home")
        #expect(!host.probedOnMainThread)
        let hostCalls = host.callCount
        service.openProject(at: URL(fileURLWithPath: "/fixture/local-project"))
        await service.ensureRuntimesDiscovered()
        #expect(service.executableCandidates("tool-b").map(\.executableURL.path) == ["/fixture/local-bin/tool-b"])
        #expect(service.processEnvironment()["HOME"] == nil)
        #expect(host.callCount == hostCalls)
    }
}

private final class FixtureRuntimeHost: RemoteRuntimeProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var onMain = false
    private var environmentHook: (@Sendable () -> Void)?
    let failsEnvironment: Bool
    init(failsEnvironment: Bool = false) { self.failsEnvironment = failsEnvironment }
    var callCount: Int { lock.withLock { calls } }
    var probedOnMainThread: Bool { lock.withLock { onMain } }
    var beforeEnvironment: (@Sendable () -> Void)? {
        get { lock.withLock { environmentHook } }
        set { lock.withLock { environmentHook = newValue } }
    }
    private func record(_ session: String) {
        #expect(session == "fixture-host")
        lock.withLock { calls += 1; onMain = onMain || Thread.isMainThread }
    }
    func runtimeEnvironment(session: String) throws -> [String: String] {
        record(session)
        beforeEnvironment?()
        if failsEnvironment { throw RemoteProbeFailure(code: "connection_closed", message: "fixture disconnected") }
        return ["HOME": "/host/home", "PATH": "/host/bin"]
    }
    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry] {
        record(session)
        guard path == "/host/bin" else { return [] }
        return [
            RemoteDirectoryEntry(name: "tool-a", metadata: .init(kind: "symlink", symlinkTargetKind: "file", symlinkTargetMode: 0o755)),
            RemoteDirectoryEntry(name: "tool-b", metadata: .init(kind: "file", mode: 0o755)),
            RemoteDirectoryEntry(name: "not-executable", metadata: .init(kind: "file", mode: 0o644)),
            RemoteDirectoryEntry(name: "not-executable-link", metadata: .init(kind: "symlink", symlinkTargetKind: "file", symlinkTargetMode: 0o644))
        ]
    }
    func runtimeExecutable(_ path: String, session: String) throws -> Bool {
        record(session)
        return false
    }
}

private struct FixtureLocalRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/fixture/local-bin"] }
    func isExecutable(at url: URL) -> Bool { url.path == "/fixture/local-bin/tool-b" }
}
