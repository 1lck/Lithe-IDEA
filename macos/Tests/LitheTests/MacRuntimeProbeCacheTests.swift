import Foundation
import Testing
@testable import Lithe

@Suite("Runtime version probe cache")
struct MacRuntimeProbeCacheTests {
    @Test
    func reusesSuccessfulResultsAndRetriesFailures() async {
        await onWorker {
            let cache = MacRuntimeProbeCache()
            let key = MacRuntimeProbeCache.Key(executablePath: "/fixture/tool-a", identity: "one")
            var calls = 0
            let failed = cache.value(for: key) { calls += 1; return nil }
            let success = cache.value(for: key) { calls += 1; return "21" }
            let reused = cache.value(for: key) { calls += 1; return "unexpected" }
            #expect(failed == nil)
            #expect(success == "21" && reused == "21")
            #expect(calls == 2)
        }
    }

    @Test
    func invalidationDiscardsCompletedAndInFlightResults() async {
        await onWorker {
            let cache = MacRuntimeProbeCache()
            let key = MacRuntimeProbeCache.Key(executablePath: "/fixture/tool-a", identity: "one")
            var calls = 0
            #expect(cache.value(for: key) {
                calls += 1
                cache.invalidate()
                return "old"
            } == "old")
            #expect(cache.value(for: key) { calls += 1; return "new" } == "new")
            cache.invalidate()
            #expect(cache.value(for: key) { calls += 1; return "refreshed" } == "refreshed")
            #expect(calls == 3)
        }
    }

    @Test
    func simultaneousRequestsShareOneProbe() async throws {
        let cache = MacRuntimeProbeCache()
        let key = MacRuntimeProbeCache.Key(executablePath: "/fixture/tool-a", identity: "one")
        let gate = ProbeGate()
        let (started, start) = AsyncStream<Void>.makeStream()
        defer { gate.release(); start.finish() }
        let first = Task {
            await onWorker {
                cache.value(for: key) {
                    start.yield(())
                    return gate.probe()
                }
            }
        }
        defer { first.cancel() }
        // The worker gate has a local deadline, so a broken probe cannot keep
        // either task alive beyond this test's cleanup.
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in started { return true }; return false }
            group.addTask {
                // test-stability: allow(swift-real-sleep) reason: deadline bounds a missing native worker event; successful completion uses the event.
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let received = await group.next() ?? false
            group.cancelAll()
            return received
        }
        guard received else {
            gate.release()
            _ = await first.value
            Issue.record("Native worker did not start before the deadline")
            return
        }
        let second = Task {
            await onWorker {
                gate.release()
                return cache.value(for: key) { gate.probe() }
            }
        }
        defer { second.cancel() }
        let results = await (first.value, second.value)
        #expect(results.0 == "21" && results.1 == "21")
        #expect(gate.calls == 1)
    }

    private func onWorker<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}

private final class ProbeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var count = 0
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func probe() -> String? {
        condition.lock()
        defer { condition.unlock() }
        count += 1
        let deadline = Date().addingTimeInterval(2)
        while !released {
            // Bounded native gate: native synchronous cache is exercised only on a dispatch worker with a local deadline.
            guard condition.wait(until: deadline) else { return nil }
        }
        return "21"
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
