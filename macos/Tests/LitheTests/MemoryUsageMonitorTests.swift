import Combine
import Foundation
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct MemoryUsageMonitorTests {
    @Test
    func managedProcessRegistryTracksModuleOwnershipAndLegacyCategories() {
        let registry = ManagedProcessRegistry()
        registry.register(pid: 101, category: .languageServer, moduleID: .languageIntelligence)
        registry.register(pid: 202, category: .service, moduleID: .execution)

        #expect(registry.processIDs(for: .languageServer) == [101])
        #expect(registry.processIDs(for: .service) == [202])
        #expect(registry.processIDs(for: .languageIntelligence) == [101])
        #expect(registry.processCount(for: .execution) == 1)

        registry.unregister(pid: 101, category: .languageServer, moduleID: .languageIntelligence)
        #expect(registry.processIDs(for: .languageIntelligence).isEmpty)
        #expect(registry.processIDs(for: .languageServer).isEmpty)
    }

    @Test
    func managedProcessCategoriesAggregateAndRelease() {
        let registry = ManagedProcessRegistry()
        let sampler = StubMemorySampler(main: 100, values: [11: 20, 22: 30])
        let monitor = MemoryUsageMonitor(
            processRegistry: registry,
            memorySampler: sampler
        )

        monitor.start()
        #expect(monitor.litheBytes == 100)
        #expect(monitor.lspBytes == 0)
        #expect(monitor.serviceBytes == 0)
        #expect(monitor.languageServerProcessCount == 0)
        #expect(monitor.serviceProcessCount == 0)
        #expect(monitor.totalManagedBytes == 100)

        registry.register(pid: 11, category: .languageServer)
        registry.register(pid: 22, category: .service)
        monitor.sampleForTesting()
        #expect(monitor.lspBytes == 20)
        #expect(monitor.serviceBytes == 30)
        #expect(monitor.languageServerProcessCount == 1)
        #expect(monitor.serviceProcessCount == 1)
        #expect(monitor.totalManagedBytes == 150)

        registry.unregister(pid: 11, category: .languageServer)
        monitor.sampleForTesting()
        #expect(monitor.lspBytes == 0)
        #expect(monitor.serviceBytes == 30)
        #expect(monitor.languageServerProcessCount == 0)
        #expect(monitor.serviceProcessCount == 1)
        #expect(monitor.totalManagedBytes == 130)
    }

    /// The monitor is an environment object of the whole workbench, so a sample
    /// that reports identical byte counts must not wake the view tree.
    @Test
    func unchangedSamplePublishesNothingWhileChangedSamplePublishesOnce() {
        let registry = ManagedProcessRegistry()
        let sampler = StubMemorySampler(main: 100, values: [11: 20])
        let monitor = MemoryUsageMonitor(
            processRegistry: registry,
            memorySampler: sampler
        )

        monitor.start()

        var publishCount = 0
        let observation = monitor.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        monitor.sampleForTesting()
        monitor.sampleForTesting()
        #expect(publishCount == 0)

        registry.register(pid: 11, category: .languageServer)
        monitor.sampleForTesting()
        #expect(publishCount == 1)

        monitor.sampleForTesting()
        #expect(publishCount == 1)
        #expect(monitor.totalManagedBytes == 120)
    }

    /// The popover shows the running average and runtime, both of which move on
    /// every sample, so it must opt back into per-sample updates.
    @Test
    func detailedUsageVisibilityRestoresPerSamplePublishing() {
        let monitor = MemoryUsageMonitor(
            processRegistry: ManagedProcessRegistry(),
            memorySampler: StubMemorySampler(main: 100, values: [:])
        )

        monitor.start()

        var publishCount = 0
        let observation = monitor.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        monitor.sampleForTesting()
        #expect(publishCount == 0)

        monitor.setDetailedUsageVisible(true)
        monitor.sampleForTesting()
        monitor.sampleForTesting()
        #expect(publishCount == 2)

        monitor.setDetailedUsageVisible(false)
        monitor.sampleForTesting()
        #expect(publishCount == 2)
    }
}

private struct StubMemorySampler: ManagedProcessMemorySampling {
    let main: UInt64
    let values: [Int32: UInt64]

    func currentProcessResidentMemoryBytes() -> UInt64? { main }
    func residentMemoryBytes(for processIDs: Set<Int32>) -> UInt64 {
        processIDs.reduce(0) { $0 + (values[$1] ?? 0) }
    }
}
