import Combine
import Foundation

enum ManagedProcessCategory: String, Sendable {
    case languageServer
    case service
}

final class ManagedProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ManagedProcessCategory: Set<Int32>] = [:]

    func register(pid: Int32, category: ManagedProcessCategory) {
        guard pid > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        entries[category, default: []].insert(pid)
    }

    func unregister(pid: Int32, category: ManagedProcessCategory) {
        lock.lock(); defer { lock.unlock() }
        entries[category]?.remove(pid)
    }

    func processIDs(for category: ManagedProcessCategory) -> Set<Int32> {
        lock.lock(); defer { lock.unlock() }
        return entries[category] ?? []
    }
}

protocol ManagedProcessMemorySampling: Sendable {
    func currentProcessResidentMemoryBytes() -> UInt64?
    func residentMemoryBytes(for processIDs: Set<Int32>) -> UInt64
}

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
    private let processRegistry: ManagedProcessRegistry
    private let memorySampler: any ManagedProcessMemorySampling
    private var sampleTimer: Timer?
    private var sampleCount: UInt64 = 0
    private var totalSampledBytes: UInt64 = 0

    init(
        sampleInterval: TimeInterval = 1.0,
        startedAt: Date = Date(),
        baselineReporter: @escaping (String) -> Void = { _ in },
        processRegistry: ManagedProcessRegistry = ManagedProcessRegistry(),
        memorySampler: any ManagedProcessMemorySampling
    ) {
        self.sampleInterval = sampleInterval
        self.startedAt = startedAt
        self.baselineReporter = baselineReporter
        self.processRegistry = processRegistry
        self.memorySampler = memorySampler
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

    private(set) var litheBytes: UInt64?
    private(set) var lspBytes: UInt64 = 0
    private(set) var serviceBytes: UInt64 = 0
    var totalManagedBytes: UInt64 { currentBytes ?? 0 }
    var litheText: String { formatted(litheBytes) }
    var lspText: String { formatted(lspBytes) }
    var serviceText: String { formatted(serviceBytes) }
    var totalText: String { formatted(totalManagedBytes) }

    #if DEBUG
    func sampleForTesting() { sample() }
    #endif

    private func sample() {
        elapsedTime = max(0, Date().timeIntervalSince(startedAt))
        guard let bytes = memorySampler.currentProcessResidentMemoryBytes() else { return }

        litheBytes = bytes
        lspBytes = memorySampler.residentMemoryBytes(for: processRegistry.processIDs(for: .languageServer))
        serviceBytes = memorySampler.residentMemoryBytes(for: processRegistry.processIDs(for: .service))
        let total = bytes + lspBytes + serviceBytes
        currentBytes = total
        if total > (peakBytes ?? 0) {
            peakBytes = total
        }
        sampleCount += 1
        totalSampledBytes += total
        averageBytes = totalSampledBytes / sampleCount
        if logsPerformanceBaseline, sampleCount == 1 {
            let milliseconds = Int((elapsedTime * 1_000).rounded())
            baselineReporter("LITHE_BASELINE_READY elapsed_ms=\(milliseconds) resident_bytes=\(total)")
        }
    }

    private func formatted(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .memory
        )
    }

}
