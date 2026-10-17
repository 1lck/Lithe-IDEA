import Foundation

/// Native CPU and RSS for a launched root and its descendants (including Maven's
/// forked test JVMs). No JVM attach, process-name scan, or helper process is needed.
enum MacProcessTreePerformanceSampler {
    struct CPU: Equatable {
        let nanoseconds: UInt64
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
    }

    static func cpuPercent(previous: [Int32: CPU], current: [Int32: CPU], elapsed: UInt64, processors: Int) -> Double? {
        guard elapsed > 0 else { return nil }
        let delta = current.reduce(0.0) { total, entry in
            let (pid, cpu) = entry
            if let old = previous[pid], old.startedSeconds == cpu.startedSeconds,
               old.startedMicroseconds == cpu.startedMicroseconds {
                return total + Double(cpu.nanoseconds >= old.nanoseconds ? cpu.nanoseconds - old.nanoseconds : 0)
            }
            // A newly forked/reused PID contributes only its own lifetime CPU.
            return total + Double(cpu.nanoseconds)
        }
        return min(100, delta / Double(elapsed) / Double(max(1, processors)) * 100)
    }

    static func samples(processID: Int32) -> AsyncThrowingStream<DebugPerformanceSample, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                let sampler = MacProcessMemorySampler()
                guard processID > 0, let root = sampler.cpuSnapshot(for: processID) else {
                    continuation.finish(throwing: DebugPerformanceError.unavailable("The test process is no longer running."))
                    return
                }
                // Anchor to process age so collapsing and reopening the monitor
                // does not append a new zero-based timeline to retained history.
                let initialAge = max(0, Date().timeIntervalSince1970 - Double(root.startedSeconds)
                    - Double(root.startedMicroseconds) / 1_000_000)
                let started = DispatchTime.now().uptimeNanoseconds
                var previousTime = started
                var previous: [Int32: CPU] = [:]
                while !Task.isCancelled {
                    guard let identity = sampler.cpuSnapshot(for: processID),
                          identity.startedSeconds == root.startedSeconds,
                          identity.startedMicroseconds == root.startedMicroseconds else { break }
                    let owned = sampler.descendantProcessIDs(of: [processID])
                    let current = owned.reduce(into: [Int32: CPU]()) { result, pid in
                        if let cpu = sampler.cpuSnapshot(for: pid) {
                            result[pid] = CPU(nanoseconds: cpu.nanoseconds,
                                startedSeconds: cpu.startedSeconds, startedMicroseconds: cpu.startedMicroseconds)
                        }
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let memory = sampler.residentMemoryBytes(forExactProcessIDs: owned)
                    // The first observation establishes CPU baselines instead of
                    // attributing pre-monitoring work to the first interval.
                    let percent = previous.isEmpty ? nil : cpuPercent(previous: previous, current: current,
                        elapsed: now - previousTime, processors: ProcessInfo.processInfo.activeProcessorCount)
                    continuation.yield(DebugPerformanceSample(timestamp: initialAge + Double(now - started) / 1_000_000_000,
                        cpuPercent: percent, memoryUsedBytes: memory, memoryCapacityBytes: memory))
                    previous = current
                    previousTime = now
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
