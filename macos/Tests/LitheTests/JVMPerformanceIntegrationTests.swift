import Darwin
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Real JVM performance integration", .serialized)
struct JVMPerformanceIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_TEST_JAVA_EXECUTABLE"] != nil))
    func realJVMReportsHeapAndCPUAndCancellationReapsTheCollector() async throws {
        let java = try #require(ProcessInfo.processInfo.environment["LITHE_TEST_JAVA_EXECUTABLE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("LithePerformanceProbe.java")
        try """
        public class LithePerformanceProbe {
          static final byte[] retained = new byte[64 * 1024 * 1024];
          static volatile long counter;
          public static void main(String[] args) {
            System.out.println("LITHE_READY " + ProcessHandle.current().pid());
            long end = System.nanoTime() + 20000000000L;
            while (System.nanoTime() < end) { retained[(int)(counter++ % retained.length)]++; }
          }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let process = MacStreamingProcess()
        defer { process.stop() }
        let readiness = JVMProbeReadiness()
        process.onOutput = { readiness.receive($0) }
        try process.start(ProcessRequest(executablePath: java, arguments: [source.path], timeoutMilliseconds: 25_000))
        #expect(await readiness.ready.waitUntilOpen(timeout: .seconds(15)))
        let pid = try #require(readiness.processID)
        let registry = ManagedProcessRegistry()
        let sampler = MacDebugPerformanceSampler(processRegistry: registry)
        let received = TestGate()
        var samples: [DebugPerformanceSample] = []
        var failure: String?
        let job = Task { @MainActor in
            do {
                for try await sample in sampler.samples(for: DebugPerformanceTarget(processID: pid,
                    javaExecutable: URL(fileURLWithPath: java))) {
                    samples.append(sample)
                    if samples.count >= 3 { received.open() }
                }
            } catch { failure = error.localizedDescription; received.open() }
        }
        defer { job.cancel() }
        #expect(await received.waitUntilOpen(timeout: .seconds(10)))
        #expect(failure == nil, "Collector failure: \(failure ?? "")")
        #expect(samples.count >= 3)
        #expect(samples.allSatisfy { $0.memoryUsedBytes > 16 * 1024 * 1024 && $0.memoryUsedBytes <= $0.memoryCapacityBytes })
        #expect(samples.compactMap(\.cpuPercent).contains { $0.isFinite && $0 > 0 && $0 <= 100 })
        let collectorPIDs = registry.processIDs(for: ManagedProcessCategory.service)
        #expect(collectorPIDs.count == 1)
        job.cancel()
        await job.value
        #expect(registry.processIDs(for: ManagedProcessCategory.service).isEmpty)
        // Observe the OS process boundary: registry removal precedes the native
        // process group's bounded forced termination. Never infer reaping from it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while collectorPIDs.contains(where: { kill($0, 0) == 0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(collectorPIDs.allSatisfy { kill($0, 0) != 0 }, "jstat must exit after cancellation")
        #expect(await process.stopAndWait())
    }
}

private final class JVMProbeReadiness: @unchecked Sendable {
    let ready = TestGate()
    private let lock = NSLock()
    private var pending = ""
    private var pid: Int32?
    var processID: Int32? { lock.withLock { pid } }
    func receive(_ chunk: String) {
        let complete = lock.withLock { () -> Bool in
            pending = String((pending + chunk).suffix(1024))
            guard let line = pending.split(separator: "\n").first(where: { $0.hasPrefix("LITHE_READY ") }),
                  let value = Int32(line.dropFirst("LITHE_READY ".count)) else { return false }
            pid = value
            return true
        }
        if complete { ready.open() }
    }
}
