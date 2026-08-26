import AppKit
import Testing
@testable import Lithe

@Suite("Split handle updates")
struct SplitHandleViewTests {
    @Test
    func pendingDragUpdatesCoalesceToNewestTranslation() {
        var buffer = FrameCoalescedDragUpdateBuffer()

        let scheduledFirstDelivery = buffer.submit(12)
        let scheduledSecondDelivery = buffer.submit(28)
        let scheduledThirdDelivery = buffer.submit(41)
        let deliveredTranslation = buffer.takePendingValue()

        #expect(scheduledFirstDelivery)
        #expect(!scheduledSecondDelivery)
        #expect(!scheduledThirdDelivery)
        #expect(deliveredTranslation == 41)
        #expect(!buffer.hasScheduledDelivery)
    }

    @Test
    func cancelledDragUpdateDoesNotLeakIntoNextDrag() {
        var buffer = FrameCoalescedDragUpdateBuffer()
        let scheduledCancelledDelivery = buffer.submit(24)
        #expect(scheduledCancelledDelivery)

        buffer.cancel()

        #expect(buffer.pendingValue == nil)
        #expect(!buffer.hasScheduledDelivery)
        let scheduledNextDelivery = buffer.submit(7)
        let deliveredTranslation = buffer.takePendingValue()
        #expect(scheduledNextDelivery)
        #expect(deliveredTranslation == 7)
    }
}
