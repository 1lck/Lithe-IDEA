import CoreGraphics

/// Stores the newest continuous-drag value while one display-frame delivery
/// is pending, preventing intermediate pointer events from queuing layouts.
struct FrameCoalescedDragUpdateBuffer {
    private(set) var pendingValue: CGFloat?
    private(set) var hasScheduledDelivery = false

    mutating func submit(_ value: CGFloat) -> Bool {
        pendingValue = value
        guard !hasScheduledDelivery else { return false }
        hasScheduledDelivery = true
        return true
    }

    mutating func takePendingValue() -> CGFloat? {
        defer {
            pendingValue = nil
            hasScheduledDelivery = false
        }
        return pendingValue
    }

    mutating func cancel() {
        pendingValue = nil
        hasScheduledDelivery = false
    }
}
