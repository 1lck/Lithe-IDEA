import Combine
import Darwin
import Foundation

/// Tracks the current process's resident memory from application launch.
@MainActor
final class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var currentBytes: UInt64?
    @Published private(set) var averageBytes: UInt64?
    @Published private(set) var peakBytes: UInt64?
    @Published private(set) var elapsedTime: TimeInterval = 0

    private let sampleInterval: TimeInterval
    private let startedAt: Date
    private let logsPerformanceBaseline: Bool
    private let baselineReporter: (String) -> Void
    private var sampleTimer: Timer?
    private var sampleCount: UInt64 = 0
    private var totalSampledBytes: UInt64 = 0

    init(
        sampleInterval: TimeInterval = 1.0,
        startedAt: Date = Date(),
        baselineReporter: @escaping (String) -> Void = { _ in }
    ) {
        self.sampleInterval = sampleInterval
        self.startedAt = startedAt
        self.baselineReporter = baselineReporter
        logsPerformanceBaseline = ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1"
    }

    deinit {
        sampleTimer?.invalidate()
    }

    func start() {
        guard sampleTimer == nil else { return }

        sample()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
    }

    var currentText: String {
        formatted(currentBytes)
    }

    var averageText: String {
        formatted(averageBytes)
    }

    var peakText: String {
        formatted(peakBytes)
    }

    var runtimeText: String {
        let totalSeconds = max(0, Int(elapsedTime.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    var samplingIntervalText: String {
        if sampleInterval.rounded() == sampleInterval {
            return "\(Int(sampleInterval))s"
        }
        return String(format: "%.1fs", sampleInterval)
    }

    private func sample() {
        elapsedTime = max(0, Date().timeIntervalSince(startedAt))
        guard let bytes = Self.currentResidentMemoryBytes() else { return }

        currentBytes = bytes
        if bytes > (peakBytes ?? 0) {
            peakBytes = bytes
        }
        sampleCount += 1
        totalSampledBytes += bytes
        averageBytes = totalSampledBytes / sampleCount
        if logsPerformanceBaseline, sampleCount == 1 {
            let milliseconds = Int((elapsedTime * 1_000).rounded())
            baselineReporter("LITHE_BASELINE_READY elapsed_ms=\(milliseconds) resident_bytes=\(bytes)")
        }
    }

    private func formatted(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .memory
        )
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
