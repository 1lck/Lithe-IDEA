import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Real test JVM profiling", .serialized)
struct TestJFRIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_TEST_JAVA_EXECUTABLE"] != nil))
    func ownedWorkerReportsRealHeapAndProducesJFRAnalysis() async throws {
        let java = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LITHE_TEST_JAVA_EXECUTABLE"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ConsoleLauncher.java")
        try """
        package org.junit.platform.console;
        public class ConsoleLauncher {
          static volatile Object sink;
          static final byte[] retained = new byte[16 * 1024 * 1024];
          public static void main(String[] args) {
            System.out.println("READY");
            long end = System.nanoTime() + 25000000000L;
            long count = 0;
            while (System.nanoTime() < end) {
              sink = new byte[128 * 1024];
              retained[(int)(count++ % retained.length)]++;
            }
          }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: MacProcessRunner().run(ProcessRequest(
                    executablePath: java.deletingLastPathComponent().appendingPathComponent("javac").path,
                    arguments: ["-d", directory.path, source.path], timeoutMilliseconds: 8000)))
            }
        }
        #expect(compile.succeeded, "\(compile.output)")
        let process = MacStreamingProcess()
        defer { process.stop() }
        let probe = JFRWorkerProbe()
        process.onOutput = { probe.receive($0) }
        process.onStateChange = { if $0.state == .running { probe.processID = $0.processID } }
        try process.start(ProcessRequest(executablePath: java.path,
            arguments: ["-Xmx128m", "-cp", directory.path, "org.junit.platform.console.ConsoleLauncher"], timeoutMilliseconds: 30_000))
        let provider = MacTestJVMPerformance(processRegistry: nil)
        var recording: TestJVMRecording?
        var collector: Task<Void, Never>?
        do {
            #expect(await probe.ready.waitUntilOpen(timeout: .seconds(5)))
            let root = try #require(probe.processID)
            var worker: TestJVMProcess?
            let discovered = TestGate()
            let discovery = Task { @MainActor in
                for try await workers in provider.processes(rootProcessID: root) {
                    if let first = workers.first { worker = first; discovered.open(); break }
                }
            }
            defer { discovery.cancel() }
            #expect(await discovered.waitUntilOpen())
            let target = try #require(worker)
            #expect(target.processID == root)
            let value = try await provider.startRecording(target)
            recording = value
            let received = TestGate()
            var samples: [DebugPerformanceSample] = []
            var failure: String?
            collector = Task { @MainActor in
                do {
                    for try await sample in MacDebugPerformanceSampler(processRegistry: nil).samples(for: target.target) {
                        samples.append(sample)
                        if samples.count >= 3 { received.open() }
                    }
                } catch { failure = error.localizedDescription; received.open() }
            }
            #expect(await received.waitUntilOpen(timeout: .seconds(6)))
            #expect(failure == nil)
            #expect(samples.count >= 3)
            #expect(samples.allSatisfy { $0.memoryUsedBytes > 8 * 1024 * 1024 })
            collector?.cancel(); await collector?.value
            try await provider.stopRecording(value)
            let report = try await provider.report(value)
            #expect(report.contains("JDK Flight Recorder"))
            #expect(report.contains("ExecutionSample"))
            #expect(report.contains("ConsoleLauncher"))
            #expect(report.contains("allocation-by-site"))
            #expect(!report.contains("Unknown command"))
            await provider.discard(value)
            #expect(!FileManager.default.fileExists(atPath: value.fileURL.deletingLastPathComponent().path))
            #expect(await process.stopAndWait())
        } catch {
            collector?.cancel(); await collector?.value
            if let recording { await provider.discard(recording) }
            _ = await process.stopAndWait()
            throw error
        }
    }
}

private final class JFRWorkerProbe: @unchecked Sendable {
    let ready = TestGate()
    private let lock = NSLock()
    private var pid: Int32?
    private var text = ""
    var processID: Int32? {
        get { lock.withLock { pid } }
        set { lock.withLock { pid = newValue } }
    }
    func receive(_ chunk: String) {
        if lock.withLock({ text = String((text + chunk).suffix(128)); return text.contains("READY\n") }) { ready.open() }
    }
}
