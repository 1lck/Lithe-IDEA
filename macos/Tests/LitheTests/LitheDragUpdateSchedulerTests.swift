import CoreGraphics
import Testing
@testable import Lithe

/// Drives `LitheDragUpdateScheduler` in manual delivery mode so coalescing, the
/// deadband, and cancellation are observable without spinning a run loop.
@MainActor
@Suite("Drag update scheduler")
struct LitheDragUpdateSchedulerTests {
    private func makeScheduler() -> LitheDragUpdateScheduler {
        LitheDragUpdateScheduler(delivery: .manual)
    }

    @Test
    func aBurstDeliversOnlyTheNewestValueOnce() {
        let scheduler = makeScheduler()
        var delivered: [CGFloat] = []

        scheduler.submit(12) { delivered.append($0) }
        scheduler.submit(28) { delivered.append($0) }
        scheduler.submit(41) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()

        #expect(delivered == [41])

        // A second flush has nothing left to deliver, proving the burst
        // collapsed into exactly one update.
        scheduler.flushPendingDeliveryForTesting()
        #expect(delivered == [41])
    }

    @Test
    func subPointChangesAreSuppressedAfterDelivery() {
        let scheduler = makeScheduler()
        var delivered: [CGFloat] = []

        scheduler.submit(100) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()
        // 0.5pt movement from the delivered value is below the default deadband
        // and must not queue anything.
        scheduler.submit(100.5) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()

        #expect(delivered == [100])

        // A movement past the deadband delivers again.
        scheduler.submit(102) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()
        #expect(delivered == [100, 102])
    }

    @Test
    func zeroDeadbandDeliversEveryDistinctValue() {
        let scheduler = makeScheduler()
        var delivered: [CGFloat] = []

        // The diff wheel path disables the deadband so sub-point steps still move.
        scheduler.submit(10, minimumChange: 0) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()
        scheduler.submit(10.25, minimumChange: 0) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()

        #expect(delivered == [10, 10.25])
    }

    @Test
    func pendingValueReflectsInFlightTargetAndClearsOnDelivery() {
        let scheduler = makeScheduler()

        #expect(scheduler.pendingValue == nil)
        scheduler.submit(30, minimumChange: 0) { _ in }
        scheduler.submit(55, minimumChange: 0) { _ in }
        // Wheel accumulation reads this to add onto the in-flight target.
        #expect(scheduler.pendingValue == 55)

        scheduler.flushPendingDeliveryForTesting()
        #expect(scheduler.pendingValue == nil)
    }

    @Test
    func cancelDropsPendingDeliveryAndResetsDeadband() {
        let scheduler = makeScheduler()
        var delivered: [CGFloat] = []

        scheduler.submit(70) { delivered.append($0) }
        scheduler.cancel()
        scheduler.flushPendingDeliveryForTesting()
        #expect(delivered.isEmpty)

        // A value that would have fallen inside the previous deadband still
        // delivers, proving the deadband was reset along with the gesture.
        scheduler.submit(70.5) { delivered.append($0) }
        scheduler.flushPendingDeliveryForTesting()
        #expect(delivered == [70.5])
    }

    @Test
    func benchmarkReportsBurstCompression() {
        let scheduler = makeScheduler()
        var delivered: [CGFloat] = []

        // A high-frequency pointer stream must produce one layout update for
        // the burst, keeping the measurable work proportional to display turns.
        for value in stride(from: CGFloat(0), to: 240, by: 1) {
            scheduler.submit(value, minimumChange: 0) { delivered.append($0) }
        }
        scheduler.flushPendingDeliveryForTesting()

        #expect(scheduler.submittedCount == 240)
        #expect(scheduler.deliveredCount == 1)
        #expect(Double(scheduler.deliveredCount) / Double(scheduler.submittedCount) <= 0.01)
        #expect(delivered == [239])
    }
}
