import Foundation
import Testing
@testable import Lithe

@Suite("Asynchronous runtime restoration")
@MainActor
struct ProjectRuntimeLoadingTests {
    @Test(arguments: ["complete", "switch", "cancel"])
    func hostProbeLeavesMainActorAvailableAndDiscardsStaleDiscovery(outcome: String) async {
        let (started, start) = AsyncStream<Void>.makeStream()
        let locator = LoadingRuntimeLocator(started: start)
        let service = ProjectRuntimeService(runtimeLocator: locator)
        let root = URL(fileURLWithPath: "/fixture/workspace")
        service.openProject(at: root)
        let load = Task { await service.ensureRuntimesDiscovered() }
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
            await load.value
            Issue.record("Discovery did not reach its bounded worker gate")
            return
        }
        // This code executes on MainActor while the synchronous host probe is held.
        if outcome == "switch" { service.openProject(at: URL(fileURLWithPath: "/fixture/other")) }
        if outcome == "cancel" { load.cancel() }
        locator.release()
        await load.value
        #expect(locator.firstProbeSawCancellation == (outcome == "cancel"))
        // A completed probe is remembered; a discarded one runs again on the next request.
        let probes = locator.probeCount
        await service.ensureRuntimesDiscovered()
        #expect(locator.probeCount == (outcome == "complete" ? probes : probes + 1))
        #expect(!locator.probedOnMainThread)
    }

    @Test
    func automaticDiscoveryReusesCacheWhileExplicitRefreshInvalidatesIt() async {
        let (_, start) = AsyncStream<Void>.makeStream()
        defer { start.finish() }
        let locator = LoadingRuntimeLocator(started: start)
        locator.release()
        let service = ProjectRuntimeService(runtimeLocator: locator)
        defer { service.closeProject() }
        service.openProject(at: URL(fileURLWithPath: "/fixture/workspace"))
        await service.ensureRuntimesDiscovered()
        await service.ensureRuntimesDiscovered()
        #expect(locator.invalidations == 0)
        #expect(locator.probeCount == 1)
        await service.refreshAvailableRuntimes()
        #expect(locator.invalidations == 1)
        #expect(locator.probeCount == 2)
        #expect(!locator.probedOnMainThread)
    }
}

private final class LoadingRuntimeLocator: RuntimeLocator, @unchecked Sendable {
    private let gate = NSCondition()
    private let started: AsyncStream<Void>.Continuation
    private var released = false
    private var mainThread = false
    private var invalidationCount = 0
    private var probes = 0
    private var cancellationAtFirstProbeEnd: Bool?
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    var probedOnMainThread: Bool { gate.lock(); defer { gate.unlock() }; return mainThread }
    var invalidations: Int { gate.lock(); defer { gate.unlock() }; return invalidationCount }
    var probeCount: Int { gate.lock(); defer { gate.unlock() }; return probes }
    var firstProbeSawCancellation: Bool { gate.lock(); defer { gate.unlock() }; return cancellationAtFirstProbeEnd ?? false }
    func environment() -> [String: String] { [:] }
    func probeHost(isCancelled: @Sendable () -> Bool) {
        gate.lock()
        defer { gate.unlock() }
        mainThread = mainThread || Thread.isMainThread
        probes += 1
        let isFirst = probes == 1
        started.yield(())
        let deadline = Date().addingTimeInterval(2)
        while !released {
            // Bounded native gate: production-owned dispatch worker exercises a synchronous locator with a bounded native gate.
            guard gate.wait(until: deadline) else { break }
        }
        if isFirst { cancellationAtFirstProbeEnd = isCancelled() }
    }
    func invalidateProbeCache() { gate.lock(); defer { gate.unlock() }; invalidationCount += 1 }
    func release() { gate.lock(); released = true; gate.broadcast(); gate.unlock() }
    func isExecutable(at url: URL) -> Bool { false }
}
