import Foundation
import Testing
@testable import Lithe

@Suite("Asynchronous runtime restoration")
@MainActor
struct ProjectRuntimeLoadingTests {
    @Test(arguments: ["complete", "switch", "cancel"])
    func versionProbesLeaveMainActorAvailableAndDiscardStaleDiscovery(outcome: String) async {
        let (started, start) = AsyncStream<Void>.makeStream()
        let locator = LoadingRuntimeLocator(started: start)
        let service = ProjectRuntimeService(runtimeLocator: locator, store: LoadingEmptyStore())
        let root = URL(fileURLWithPath: "/fixture/workspace")
        service.openProject(at: root)
        let load = Task { try await service.loadRunConfigurationToolchainCandidates(for: nil, projectRoot: root) }
        defer { locator.release(); start.finish(); load.cancel(); service.closeProject() }
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in started { return true }; return false }
            group.addTask {
                // test-stability: allow(swift-real-sleep) reason: bounds a missing worker event; normal synchronization uses the stream.
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard received else {
            locator.release()
            _ = await load.result
            Issue.record("Discovery did not reach its bounded worker gate")
            return
        }
        // This code executes on MainActor while synchronous discovery is held.
        if outcome == "switch" { service.openProject(at: URL(fileURLWithPath: "/fixture/other")) }
        if outcome == "cancel" { load.cancel() }
        locator.release()
        switch await load.result {
        case .success(let candidates):
            #expect(outcome == "complete")
            #expect(candidates.map(\.id) == ["project-jdk", "project-maven"])
            #expect(candidates.map(\.version) == ["21.0.1", "3.9.9"])
        case .failure(let error):
            #expect(outcome != "complete")
            #expect(error is CancellationError)
            #expect(service.chooseJavaHome(overridePath: nil, detected: { nil }) == nil)
        }
        #expect(!locator.probedOnMainThread)
    }

    @Test
    func automaticDiscoveryReusesCacheWhileExplicitRefreshInvalidatesIt() async {
        let (_, start) = AsyncStream<Void>.makeStream()
        defer { start.finish() }
        let locator = LoadingRuntimeLocator(started: start)
        locator.release()
        let service = ProjectRuntimeService(runtimeLocator: locator, store: LoadingEmptyStore())
        defer { service.closeProject() }
        service.openProject(at: URL(fileURLWithPath: "/fixture/workspace"))
        await service.ensureRuntimesDiscovered()
        await service.ensureRuntimesDiscovered()
        #expect(locator.invalidations == 0)
        await service.refreshAvailableRuntimes()
        #expect(locator.invalidations == 1)
        #expect(!locator.probedOnMainThread)
    }
}

private struct LoadingEmptyStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}

private final class LoadingRuntimeLocator: RuntimeLocator, @unchecked Sendable {
    private let gate = NSCondition()
    private let started: AsyncStream<Void>.Continuation
    private var released = false
    private var mainThread = false
    private var invalidationCount = 0
    private let java = JavaRuntimeCandidate(homePath: "/fixture/jdk", version: "21.0.1", vendor: "fixture")
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    var probedOnMainThread: Bool { gate.lock(); defer { gate.unlock() }; return mainThread }
    var invalidations: Int { gate.lock(); defer { gate.unlock() }; return invalidationCount }
    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: discoverJavaRuntimes(), mavenRuntimes: []) }
    func discoverJavaRuntimes() -> [JavaRuntimeCandidate] {
        gate.lock()
        defer { gate.unlock() }
        mainThread = mainThread || Thread.isMainThread
        started.yield(())
        let deadline = Date().addingTimeInterval(2)
        while !released {
            // Bounded native gate: production-owned dispatch worker exercises a synchronous locator with a bounded native gate.
            guard gate.wait(until: deadline) else { return [] }
        }
        return [java]
    }
    func invalidateProbeCache() { gate.lock(); defer { gate.unlock() }; invalidationCount += 1 }
    func release() { gate.lock(); released = true; gate.broadcast(); gate.unlock() }
    private func recordProbe() { gate.lock(); defer { gate.unlock() }; mainThread = mainThread || Thread.isMainThread }
    func validJavaHome(path: String) -> URL? { path == java.homePath ? URL(fileURLWithPath: path) : nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { recordProbe(); return java }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { URL(fileURLWithPath: "/fixture/maven/bin/mvn") }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? {
        recordProbe()
        return MavenRuntimeCandidate(homePath: "/fixture/maven", executablePath: executableURL.path, version: "3.9.9")
    }
}
