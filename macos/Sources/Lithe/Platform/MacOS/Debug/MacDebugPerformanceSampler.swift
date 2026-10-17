import Foundation
import LitheCoreContracts

/// OpenJDK jstat owns the JVM counters. This adapter only parses its documented
/// -gc columns and combines them with CPU time for the exact launched process.
struct MacDebugPerformanceSampler: DebugPerformanceSampling {
    let processRegistry: ManagedProcessRegistry?

    func samples(for target: DebugPerformanceTarget) -> AsyncThrowingStream<DebugPerformanceSample, Error> {
        if target.javaExecutable == nil {
            return MacProcessTreePerformanceSampler.samples(processID: target.processID)
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let session = MacDebugPerformanceSession(target: target, registry: processRegistry, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

struct JStatHeapParser {
    private var header: [Substring] = []
    private var pending = ""

    mutating func append(_ chunk: String) throws -> [(uptime: Double, used: UInt64, committed: UInt64)] {
        pending += chunk
        guard pending.utf8.count <= 16_384 else { throw DebugPerformanceError.unavailable("Invalid JVM performance output.") }
        var samples: [(Double, UInt64, UInt64)] = []
        while let end = pending.firstIndex(of: "\n") {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.contains("S0U") && fields.contains("OU") { header = fields; continue }
            guard !header.isEmpty, fields.count == header.count else { continue }
            func value(_ key: String) -> Double? {
                guard let index = header.firstIndex(of: Substring(key)), let number = Double(fields[index]), number.isFinite, number >= 0 else { return nil }
                return number
            }
            guard let time = value("Timestamp") else { continue }
            let used = ["S0U", "S1U", "EU", "OU"].compactMap(value)
            let committed = ["S0C", "S1C", "EC", "OC"].compactMap(value)
            guard used.count == 4, committed.count == 4 else {
                throw DebugPerformanceError.unavailable("The JVM does not expose supported heap counters through jstat.")
            }
            let usedBytes = used.reduce(0, +) * 1024
            let committedBytes = committed.reduce(0, +) * 1024
            guard usedBytes < Double(UInt64.max), committedBytes < Double(UInt64.max), usedBytes <= committedBytes else {
                throw DebugPerformanceError.unavailable("Invalid JVM heap counters.")
            }
            samples.append((time, UInt64(usedBytes), UInt64(committedBytes)))
        }
        return samples
    }
}

private final class MacDebugPerformanceSession: @unchecked Sendable {
    private let lock = NSLock()
    private let target: DebugPerformanceTarget
    private let process: MacStreamingProcess
    private var continuation: AsyncThrowingStream<DebugPerformanceSample, Error>.Continuation?
    private var parser = JStatHeapParser()
    private let cpuSampler = MacProcessMemorySampler()
    private var previousCPU: UInt64?
    private var previousTime: UInt64?
    private var identity: (UInt64, UInt64)?
    private var lastSampleTime = DispatchTime.now().uptimeNanoseconds
    private var diagnostic = ""
    private var watchdog: DispatchSourceTimer?

    init(target: DebugPerformanceTarget, registry: ManagedProcessRegistry?,
         continuation: AsyncThrowingStream<DebugPerformanceSample, Error>.Continuation) {
        self.target = target
        process = MacStreamingProcess(processRegistry: registry, moduleID: .debug)
        self.continuation = continuation
    }

    func start() {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        guard let executable = target.javaExecutable else { lock.unlock(); finish(nil); return }
        let tool = executable.deletingLastPathComponent().appendingPathComponent("jstat")
        guard target.processID > 0, executable.lastPathComponent == "java",
              FileManager.default.isExecutableFile(atPath: tool.path),
              let cpu = cpuSampler.cpuSnapshot(for: target.processID) else {
            lock.unlock()
            finish(DebugPerformanceError.unavailable("A running local JVM and its JDK jstat tool are required.")); return
        }
        identity = (cpu.startedSeconds, cpu.startedMicroseconds)
        previousCPU = cpu.nanoseconds
        previousTime = DispatchTime.now().uptimeNanoseconds
        process.onOutput = { [weak self] chunk in self?.receive(chunk) }
        process.onTermination = { [weak self] code in
            guard let self else { return }
            let message = lock.withLock { self.diagnostic }
            finish(code == 0 ? nil : DebugPerformanceError.unavailable(message.isEmpty ? "JVM performance monitoring ended." : message))
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = lock.withLock { DispatchTime.now().uptimeNanoseconds - self.lastSampleTime > 10_000_000_000 }
            if stalled { finish(DebugPerformanceError.unavailable("No JVM performance samples received for 10 seconds.")) }
        }
        watchdog = timer
        timer.resume()
        var startError: Error?
        do {
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            try process.start(ProcessRequest(executablePath: tool.path,
                arguments: ["-gc", "-t", String(target.processID), "1000"], environment: environment))
        } catch { startError = error }
        lock.unlock()
        if let startError { finish(startError) }
    }

    private func receive(_ chunk: String) {
        var output: [DebugPerformanceSample] = []
        var failure: Error?
        let destination = lock.withLock { () -> AsyncThrowingStream<DebugPerformanceSample, Error>.Continuation? in
            guard let continuation else { return nil }
            do {
                for heap in try parser.append(chunk) {
                    guard let cpu = cpuSampler.cpuSnapshot(for: target.processID),
                          let identity, identity.0 == cpu.startedSeconds, identity.1 == cpu.startedMicroseconds else {
                        throw DebugPerformanceError.unavailable("The monitored JVM has exited or changed.")
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    var percent: Double?
                    if let previousCPU, let previousTime, now > previousTime, cpu.nanoseconds >= previousCPU {
                        percent = min(100, Double(cpu.nanoseconds - previousCPU) / Double(now - previousTime)
                            / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) * 100)
                    }
                    previousCPU = cpu.nanoseconds; previousTime = now; lastSampleTime = now
                    output.append(DebugPerformanceSample(timestamp: heap.uptime, cpuPercent: percent,
                        memoryUsedBytes: heap.used, memoryCapacityBytes: heap.committed))
                }
                if output.isEmpty { diagnostic = String((diagnostic + chunk).suffix(1024)) }
                else { diagnostic = "" }
            } catch { failure = error }
            return continuation
        }
        if let failure { finish(failure); return }
        for sample in output { destination?.yield(sample) }
    }

    func stop() { finish(nil) }

    private func finish(_ error: Error?) {
        let (destination, timer) = lock.withLock { () -> (AsyncThrowingStream<DebugPerformanceSample, Error>.Continuation?, DispatchSourceTimer?) in
            let destination = continuation
            continuation = nil
            let timer = watchdog
            watchdog = nil
            return (destination, timer)
        }
        guard let destination else { return }
        timer?.cancel()
        process.stop()
        destination.finish(throwing: error)
    }
}
