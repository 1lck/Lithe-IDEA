import Foundation
import Testing
@testable import Lithe

@Suite("Runtime version probe cache")
struct MacRuntimeProbeCacheTests {
    @Test
    func reusesSuccessfulResultsAndRetriesFailures() async {
        await onWorker {
            let cache = MacRuntimeProbeCache()
            let key = MacRuntimeProbeCache.Key(executablePath: "/fixture/java", identity: "one")
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
            let key = MacRuntimeProbeCache.Key(executablePath: "/fixture/java", identity: "one")
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
    func canonicalAliasesReuseProbeAndUpdatedReleaseReprobes() async throws {
        try await onThrowingWorker {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("jdk")
            let java = home.appendingPathComponent("bin/java")
            let log = home.appendingPathComponent("probes")
            let release = home.appendingPathComponent("release")
            try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
            // All paths belong to the disposable fixture. The script records real
            // process invocations without relying on an installed developer tool.
            try Data("#!/bin/sh\necho probe >> \"$(dirname \"$0\")/../probes\"\necho 'openjdk version \"21.0.1\"' >&2\n".utf8).write(to: java)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
            try Data("first".utf8).write(to: release)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
            #expect(MacRuntimeDiscovery.probeJavaHome(home)?.version == "21.0.1")
            #expect(MacRuntimeDiscovery.probeJavaHome(alias)?.homePath == alias.path)
            #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 1)
            try Data("updated release identity".utf8).write(to: release)
            #expect(MacRuntimeDiscovery.probeJavaHome(home)?.version == "21.0.1")
            #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 2)
        }
    }

    @Test
    func mavenWrapperReusesVersionUntilDistributionChanges() async throws {
        try await onThrowingWorker {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("mvnw")
            let properties = root.appendingPathComponent(".mvn/wrapper/maven-wrapper.properties")
            let log = root.appendingPathComponent("probes")
            try FileManager.default.createDirectory(at: properties.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho probe >> \"$(dirname \"$0\")/probes\"\necho 'Apache Maven 3.9.9'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try Data("distributionUrl=fixture-one".utf8).write(to: properties)
            let alias = root.appendingPathComponent("alias/mvnw")
            try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
            #expect(MacRuntimeDiscovery.probeMaven(executable)?.version == "3.9.9")
            #expect(MacRuntimeDiscovery.probeMaven(alias)?.executablePath == alias.path)
            #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 1)
            try Data("distributionUrl=fixture-updated".utf8).write(to: properties)
            #expect(MacRuntimeDiscovery.probeMaven(executable)?.version == "3.9.9")
            #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 2)
        }
    }

    @Test
    func simultaneousRequestsShareOneProbe() async throws {
        let cache = MacRuntimeProbeCache()
        let key = MacRuntimeProbeCache.Key(executablePath: "/fixture/java", identity: "one")
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

    private func onThrowingWorker<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        // A native synchronous probe must run on a dispatch worker, never on the
        // cooperative executor used by Swift Testing.
        let result: Result<Value, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Result { try work() })
            }
        }
        return try result.get()
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
