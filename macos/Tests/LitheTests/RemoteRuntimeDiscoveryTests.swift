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
    func discoversHostToolsAndNormalizesOnlyAgainstRemoteHome() throws {
        let host = FixtureRuntimeHost()
        let locator = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        let result = locator.discover()
        #expect(result.javaRuntimes.map(\.homePath) == ["/host/jdk"])
        #expect(result.mavenRuntimes.map(\.version) == ["3.9.9"])
        #expect(locator.discoveryFailure == nil)
        #expect(locator.normalizedPath("~/jdk", relativeTo: Self.binding.root) == "/host/home/jdk")
        #expect(locator.normalizedPath("tools/java", relativeTo: Self.binding.root) == "/host/project/tools/java")
        #expect(locator.normalizedPath(Self.binding.root.path + "/gradlew", relativeTo: nil) == "/host/project/gradlew")
        #expect(locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/node")))
        #expect(!locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/not-executable")))
        #expect(!locator.isExecutable(at: URL(fileURLWithPath: "/host/bin/not-executable-link")))
        #expect(locator.validJavaHome(path: "/host/jdk")?.path == "/host/jdk")
        #expect(locator.validJavaHome(path: "/fixture/local-jdk") == nil)
        let calls = host.callCount
        let selection = try #require(locator.selectJavaRuntime(
            candidates: [AutomaticJavaCandidate(id: "old", version: "17", priority: 0),
                         AutomaticJavaCandidate(id: "current", version: "21", priority: 1)], fallbackID: "old"
        )).get()
        #expect(selection.id == "current")
        #expect(host.callCount == calls)
    }

    @Test
    func failedAndCancelledDiscoveryCannotPublishPartialOrLocalTools() {
        let host = FixtureRuntimeHost(failsVersion: true)
        let locator = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        #expect(locator.discover().javaRuntimes.isEmpty)
        #expect(locator.discoveryFailure != nil)
        #expect(locator.environment().isEmpty)
        #expect(locator.candidates(for: "node", projectURL: Self.binding.root, environment: ["PATH": "/host/bin"]).isEmpty)
        let calls = host.callCount
        #expect(locator.discover(isCancelled: { true }).javaRuntimes.isEmpty)
        #expect(host.callCount == calls)
    }

    @Test
    func invalidatedProbeCannotOverwriteANewerSnapshot() {
        let host = FixtureRuntimeHost()
        let locator = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        host.beforeVersion = { locator.invalidateProbeCache() }
        #expect(locator.discover().javaRuntimes.isEmpty)
        #expect(locator.environment().isEmpty)
        host.beforeVersion = nil
        #expect(locator.discover().javaRuntimes.count == 1)
    }

    @Test @MainActor
    func projectSwitchUsesHostWorkersAndNewProjectAlwaysUsesLocalDiscovery() async {
        let host = FixtureRuntimeHost()
        let remote = MacRemoteRuntimeLocator(binding: Self.binding, host: host)
        let local = FixtureLocalRuntimeLocator()
        let service = ProjectRuntimeService(runtimeLocator: local, store: FixtureRuntimeStore(),
            workspaceRuntime: { $0 == Self.binding.root ? (remote, remote) : nil })
        defer { service.closeProject() }
        service.openProject(at: Self.binding.root)
        await service.ensureRuntimesDiscovered()
        #expect(service.javaRuntimes.map(\.homePath) == ["/host/jdk"])
        #expect(service.javaHomeURL()?.path == "/host/jdk")
        #expect(!host.probedOnMainThread)
        let hostCalls = host.callCount
        let newProject = await service.discoverJavaRuntimesForNewProject()
        #expect(newProject.map(\.homePath) == ["/fixture/local-jdk"])
        #expect(host.callCount == hostCalls)
        service.openProject(at: URL(fileURLWithPath: "/fixture/local-project"))
        await service.ensureRuntimesDiscovered()
        #expect(service.javaHomeURL()?.path == "/fixture/local-jdk")
        #expect(host.callCount == hostCalls)
    }
}

private final class FixtureRuntimeHost: RemoteRuntimeProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var onMain = false
    private var versionHook: (@Sendable () -> Void)?
    let failsVersion: Bool
    init(failsVersion: Bool = false) { self.failsVersion = failsVersion }
    var callCount: Int { lock.withLock { calls } }
    var probedOnMainThread: Bool { lock.withLock { onMain } }
    var beforeVersion: (@Sendable () -> Void)? {
        get { lock.withLock { versionHook } }
        set { lock.withLock { versionHook = newValue } }
    }
    private func record(_ session: String) {
        #expect(session == "fixture-host")
        lock.withLock { calls += 1; onMain = onMain || Thread.isMainThread }
    }
    func runtimeEnvironment(session: String) throws -> [String: String] {
        record(session)
        return ["HOME": "/host/home", "JAVA_HOME": "/host/jdk", "PATH": "/host/bin"]
    }
    func runtimeRequirements(_ root: String, session: String) throws -> ToolingJSONValue {
        record(session)
        #expect(root == "/host/project")
        return .object(["version": .integer(1), "toolchains": .object([
            "project-jdk": .object(["type": .string("java"), "minimumVersion": .string("21")])
        ])])
    }
    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry] {
        record(session)
        guard path == "/host/bin" else { return [] }
        return [
            RemoteDirectoryEntry(name: "java", metadata: .init(kind: "symlink", symlinkTargetKind: "file", symlinkTargetMode: 0o755)),
            RemoteDirectoryEntry(name: "mvn", metadata: .init(kind: "file", mode: 0o755)),
            RemoteDirectoryEntry(name: "node", metadata: .init(kind: "file", mode: 0o755)),
            RemoteDirectoryEntry(name: "not-executable", metadata: .init(kind: "file", mode: 0o644)),
            RemoteDirectoryEntry(name: "not-executable-link", metadata: .init(kind: "symlink", symlinkTargetKind: "file", symlinkTargetMode: 0o644))
        ]
    }
    func runtimeRealPath(_ path: String, session: String) throws -> String {
        record(session)
        return path == "/host/bin/java" ? "/host/jdk/bin/java" : path
    }
    func runtimeExecutable(_ path: String, session: String) throws -> Bool {
        record(session)
        return ["/host/jdk/bin/java", "/host/project/gradlew"].contains(path)
    }
    func runtimeVersion(_ executable: String, session: String) throws -> String {
        record(session)
        beforeVersion?()
        if failsVersion { throw RemoteProbeFailure(code: "connection_closed", message: "fixture disconnected") }
        return executable.hasSuffix("/java") ? "openjdk version \"21.0.1\"\nOpenJDK Runtime Environment" : "Apache Maven 3.9.9"
    }
}

private struct FixtureRuntimeStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}

private struct FixtureLocalRuntimeLocator: RuntimeLocator {
    private let home = URL(fileURLWithPath: "/fixture/local-jdk")
    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [JavaRuntimeCandidate(homePath: home.path, version: "21", vendor: "fixture")], mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? { path == home.path ? home : nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { discover().javaRuntimes.first }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}
