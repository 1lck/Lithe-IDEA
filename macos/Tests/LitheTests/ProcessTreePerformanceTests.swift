import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Test process tree performance", .serialized)
struct ProcessTreePerformanceTests {
    @Test func nativeLifecycleReportsRootAndSamplerIncludesItsWorker() async throws {
        let process = MacStreamingProcess()
        defer { process.stop() }
        let recorder = ProcessTreeProbe()
        process.onStateChange = { event in
            if event.state == .running { recorder.root = event.processID }
        }
        process.onOutput = { recorder.receive($0) }
        // The shell owns a CPU-bound worker, like a build launcher owns a test JVM.
        try process.start(ProcessRequest(executablePath: "/bin/sh",
            arguments: ["-c", "/usr/bin/yes > /dev/null & echo $!; wait"], timeoutMilliseconds: 8000))
        #expect(await recorder.ready.waitUntilOpen())
        let root = try #require(recorder.root)
        let child = try #require(recorder.child)
        let sampler = MacProcessMemorySampler()
        #expect(sampler.descendantProcessIDs(of: [root]).contains(child))
        #expect(!sampler.descendantProcessIDs(of: [child]).contains(root))
        let received = TestGate()
        var samples: [DebugPerformanceSample] = []
        var error: String?
        let job = Task { @MainActor in
            do {
                for try await sample in MacDebugPerformanceSampler(processRegistry: nil)
                    .samples(for: DebugPerformanceTarget(processID: root)) {
                    samples.append(sample)
                    if samples.count == 3 { received.open() }
                }
            } catch let failure { error = failure.localizedDescription; received.open() }
        }
        defer { job.cancel() }
        #expect(await received.waitUntilOpen(timeout: .seconds(5)))
        #expect(error == nil)
        #expect(samples.count >= 3)
        #expect(samples.first?.cpuPercent == nil)
        #expect(samples.allSatisfy { $0.memoryUsedBytes > 0 })
        #expect(samples.compactMap(\.cpuPercent).contains { $0 > 0 && $0 <= 100 })
        job.cancel()
        await job.value
        let resumed = TestGate()
        var resumedTimestamp: TimeInterval?
        let resumedJob = Task { @MainActor in
            do {
                for try await sample in MacProcessTreePerformanceSampler.samples(processID: root) {
                    resumedTimestamp = sample.timestamp
                    resumed.open()
                    break
                }
            } catch { resumed.open() }
        }
        defer { resumedJob.cancel() }
        #expect(await resumed.waitUntilOpen())
        #expect((resumedTimestamp ?? -1) >= (samples.last?.timestamp ?? 0))
        resumedJob.cancel()
        await resumedJob.value
        #expect(await process.stopAndWait())
    }
}

private final class ProcessTreeProbe: @unchecked Sendable {
    let ready = TestGate()
    private let lock = NSLock()
    private var rootPID: Int32?
    private var childPID: Int32?
    private var pending = ""
    var root: Int32? {
        get { lock.withLock { rootPID } }
        set { lock.withLock { rootPID = newValue } }
    }
    var child: Int32? { lock.withLock { childPID } }
    func receive(_ chunk: String) {
        let complete = lock.withLock { () -> Bool in
            pending = String((pending + chunk).suffix(128))
            guard let end = pending.firstIndex(of: "\n"), let pid = Int32(pending[..<end]) else { return false }
            childPID = pid
            return true
        }
        if complete { ready.open() }
    }
}
