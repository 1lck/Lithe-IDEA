import Foundation

struct MacSystemDiagnosticsProvider: SystemDiagnosticsProviding {
    private let memorySampler: any ManagedProcessMemorySampling

    init(memorySampler: any ManagedProcessMemorySampling = MacProcessMemorySampler()) {
        self.memorySampler = memorySampler
    }

    func currentSnapshot(volumeURL: URL) -> SystemDiagnosticsSnapshot {
        let processInfo = ProcessInfo.processInfo
        let diskFreeBytes = (try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity
            .map(Int64.init) ?? 0
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return SystemDiagnosticsSnapshot(
            appVersion: appVersion,
            osName: "macOS",
            osVersion: processInfo.operatingSystemVersionString,
            cpuCoreCount: processInfo.activeProcessorCount,
            memoryRSSBytes: Int64(memorySampler.currentProcessResidentMemoryBytes() ?? 0),
            diskFreeBytes: diskFreeBytes
        )
    }
}
