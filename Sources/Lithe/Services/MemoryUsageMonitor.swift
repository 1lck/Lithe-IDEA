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

private struct ManagedProcessSample: Sendable {
    var languageServerBytes: UInt64 = 0
    var serviceBytes: UInt64 = 0
    var languageServerCount = 0
    var serviceCount = 0
}

/// Tracks the current process's resident memory from application launch.
@MainActor
final class MemoryUsageMonitor: ObservableObject {
    private(set) var currentBytes: UInt64?
    private(set) var averageBytes: UInt64?
    private(set) var peakBytes: UInt64?

    /// Runtime is derived on read instead of being stored, so a sample that
    /// leaves every byte count unchanged publishes nothing at all.
    var elapsedTime: TimeInterval { max(0, Date().timeIntervalSince(startedAt)) }

    private let sampleInterval: TimeInterval
    private let startedAt: Date
    private let logsPerformanceBaseline: Bool
    private let baselineReporter: (String) -> Void
    private let processRegistry: ManagedProcessRegistry
    private let memorySampler: any ManagedProcessMemorySampling
    private var sampleTimer: Timer?
    private var sampleCount: UInt64 = 0
    private var totalSampledBytes: UInt64 = 0
    private var displayedSnapshot: DisplayedSnapshot?
    private var isDetailedUsageVisible = false

    private struct DisplayedSnapshot: Equatable {
        let lithe: String
        let lsp: String
        let service: String
        let total: String
        let peak: String
        let languageServerCount: Int
        let serviceCount: Int
    }

    init(
        sampleInterval: TimeInterval = 5.0,
        startedAt: Date = Date(),
        baselineReporter: @escaping (String) -> Void = { _ in },
        logsPerformanceBaseline: Bool = false,
        processRegistry: ManagedProcessRegistry = ManagedProcessRegistry(),
        memorySampler: any ManagedProcessMemorySampling
    ) {
        self.sampleInterval = sampleInterval
        self.startedAt = startedAt
        self.baselineReporter = baselineReporter
        self.processRegistry = processRegistry
        self.memorySampler = memorySampler
        self.logsPerformanceBaseline = logsPerformanceBaseline
    }

    deinit {
        sampleTimer?.invalidate()
    }

    func start() {
        guard sampleTimer == nil else { return }

        sample()
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sampleOffMainThread()
            }
        }
        // Sampling is a status-bar refresh, so it must never extend a scroll or
        // resize run loop pass to keep its cadence.
        timer.tolerance = sampleInterval / 2
        RunLoop.main.add(timer, forMode: .default)
        sampleTimer = timer
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
    private(set) var languageServerProcessCount = 0
    private(set) var serviceProcessCount = 0
    var totalManagedBytes: UInt64 { currentBytes ?? 0 }
    var litheText: String { formatted(litheBytes) }
    var lspText: String { formatted(lspBytes) }
    var serviceText: String { formatted(serviceBytes) }
    var totalText: String { formatted(totalManagedBytes) }

    /// Set while the detailed usage popover is on screen. The popover displays the
    /// running average and runtime, which change on every sample, so it opts back
    /// into per-sample updates that the status bar does not need.
    func setDetailedUsageVisible(_ isVisible: Bool) {
        guard isDetailedUsageVisible != isVisible else { return }
        isDetailedUsageVisible = isVisible
    }

    #if DEBUG
    func sampleForTesting() { sample() }
    #endif

    private func sample() {
        guard let bytes = memorySampler.currentProcessResidentMemoryBytes() else { return }
        let sampler = memorySampler
        apply(
            litheBytes: bytes,
            managed: Self.managedSample(
                languageServerProcessIDs: processRegistry.processIDs(for: .languageServer),
                serviceProcessIDs: processRegistry.processIDs(for: .service),
                sampler: sampler
            )
        )
    }

    /// Walking the process table costs two `proc_pidinfo` calls for every process
    /// on the machine, which is far too much work to run on the main thread while
    /// the user is scrolling.
    private func sampleOffMainThread() async {
        guard let bytes = memorySampler.currentProcessResidentMemoryBytes() else { return }
        let languageServerProcessIDs = processRegistry.processIDs(for: .languageServer)
        let serviceProcessIDs = processRegistry.processIDs(for: .service)
        let sampler = memorySampler
        let managed = await Task.detached(priority: .utility) {
            Self.managedSample(
                languageServerProcessIDs: languageServerProcessIDs,
                serviceProcessIDs: serviceProcessIDs,
                sampler: sampler
            )
        }.value
        apply(litheBytes: bytes, managed: managed)
    }

    private nonisolated static func managedSample(
        languageServerProcessIDs: Set<Int32>,
        serviceProcessIDs: Set<Int32>,
        sampler: any ManagedProcessMemorySampling
    ) -> ManagedProcessSample {
        ManagedProcessSample(
            languageServerBytes: sampler.residentMemoryBytes(for: languageServerProcessIDs),
            serviceBytes: sampler.residentMemoryBytes(for: serviceProcessIDs),
            languageServerCount: languageServerProcessIDs.count,
            serviceCount: serviceProcessIDs.count
        )
    }

    private func apply(litheBytes bytes: UInt64, managed: ManagedProcessSample) {
        let total = bytes + managed.languageServerBytes + managed.serviceBytes
        sampleCount += 1
        totalSampledBytes += total
        let average = totalSampledBytes / sampleCount
        let peak = max(total, peakBytes ?? 0)

        if logsPerformanceBaseline, sampleCount == 1 {
            let milliseconds = Int((elapsedTime * 1_000).rounded())
            baselineReporter("LITHE_BASELINE_READY elapsed_ms=\(milliseconds) resident_bytes=\(total)")
        }

        litheBytes = bytes
        lspBytes = managed.languageServerBytes
        serviceBytes = managed.serviceBytes
        languageServerProcessCount = managed.languageServerCount
        serviceProcessCount = managed.serviceCount
        currentBytes = total
        averageBytes = average
        peakBytes = peak

        // Comparing rendered text rather than raw byte counts means the workbench
        // view tree is only woken when the user can actually see a difference.
        // The running average and runtime are deliberately excluded: both change
        // on every single sample by construction, and both are popover-only.
        let snapshot = DisplayedSnapshot(
            lithe: litheText,
            lsp: lspText,
            service: serviceText,
            total: totalText,
            peak: peakText,
            languageServerCount: managed.languageServerCount,
            serviceCount: managed.serviceCount
        )
        let isVisibleChange = snapshot != displayedSnapshot
        displayedSnapshot = snapshot

        // The popover shows the average and runtime, so it needs every sample
        // while it is on screen.
        guard isVisibleChange || isDetailedUsageVisible else { return }
        objectWillChange.send()
    }

    private func formatted(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .memory
        )
    }

}
