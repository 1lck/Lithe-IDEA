import Foundation

/// The process whose tree is monitored with native CPU/RSS counters.
struct DebugPerformanceTarget: Equatable, Sendable {
    let processID: Int32
}

struct DebugPerformanceSample: Equatable, Sendable, Identifiable {
    let timestamp: TimeInterval
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64
    let memoryCapacityBytes: UInt64
    var id: TimeInterval { timestamp }
}

protocol DebugPerformanceSampling: Sendable {
    func samples(for target: DebugPerformanceTarget) -> AsyncThrowingStream<DebugPerformanceSample, Error>
}

enum DebugPerformanceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}
