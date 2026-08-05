import Combine
import Darwin
import Foundation

/// Tracks the current process's resident memory from application launch.
@MainActor
final class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var currentBytes: UInt64?
    @Published private(set) var averageBytes: UInt64?

    private let sampleInterval: TimeInterval
    private var sampleTimer: Timer?
    private var sampleCount: UInt64 = 0
    private var totalSampledBytes: UInt64 = 0

    init(sampleInterval: TimeInterval = 1.0) {
        self.sampleInterval = sampleInterval
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

    private func sample() {
        guard let bytes = Self.currentResidentMemoryBytes() else { return }

        currentBytes = bytes
        sampleCount += 1
        totalSampledBytes += bytes
        averageBytes = totalSampledBytes / sampleCount
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
