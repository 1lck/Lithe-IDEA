import Foundation
import Testing
@testable import Lithe

@MainActor
struct MemoryUsageMonitorTests {
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
        #expect(monitor.totalManagedBytes == 100)

        registry.register(pid: 11, category: .languageServer)
        registry.register(pid: 22, category: .service)
        monitor.sampleForTesting()
        #expect(monitor.lspBytes == 20)
        #expect(monitor.serviceBytes == 30)
        #expect(monitor.totalManagedBytes == 150)

        registry.unregister(pid: 11, category: .languageServer)
        monitor.sampleForTesting()
        #expect(monitor.lspBytes == 0)
        #expect(monitor.serviceBytes == 30)
        #expect(monitor.totalManagedBytes == 130)
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
