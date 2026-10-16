import Foundation

struct DebugPerformanceTarget: Equatable, Sendable {
    let processID: Int32
    let javaExecutable: URL
}

struct DebugPerformanceSample: Equatable, Sendable, Identifiable {
    let timestamp: TimeInterval
    let cpuPercent: Double?
    let heapUsedBytes: UInt64
    let heapCommittedBytes: UInt64
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
