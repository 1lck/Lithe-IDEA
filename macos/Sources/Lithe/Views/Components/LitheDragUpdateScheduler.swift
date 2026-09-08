import Foundation

/// Coalesces continuous drag updates to one delivery per main run-loop turn.
///
/// Held as `@State` so the bookkeeping never invalidates the host view's body.
/// Uses `DispatchQueue.main.async` which, during `.eventTracking` mode, drains
/// at the end of the current run-loop turn with zero added latency — unlike the
/// 16ms `Task.sleep` pattern which adds a full frame of delay to every update.
///
/// `init` is `nonisolated` so that `@State` default-value initialisation —
/// which Swift 6.2 treats as a nonisolated context — compiles without a
/// diagnostic. All methods that access mutable state remain `@MainActor`.
@MainActor
final class LitheDragUpdateScheduler {
    enum Delivery {
        case mainRunLoopTurn
        #if DEBUG
        case manual
        #endif
    }

    private var buffer = FrameCoalescedDragUpdateBuffer()
    private var lastDeliveredValue: CGFloat?
    private var pendingDelivery: (@MainActor () -> Void)?
    private let delivery: Delivery

    #if DEBUG
    private(set) var submittedCount = 0
    private(set) var deliveredCount = 0
    #endif

    nonisolated init(delivery: Delivery = .mainRunLoopTurn) {
        self.delivery = delivery
    }

    var pendingValue: CGFloat? { buffer.pendingValue }

    func submit(
        _ value: CGFloat,
        minimumChange: CGFloat = 1,
        deliver: @escaping @MainActor (CGFloat) -> Void
    ) {
        #if DEBUG
        submittedCount += 1
        #endif
        if let last = lastDeliveredValue, abs(value - last) < minimumChange { return }
        guard buffer.submit(value) else { return }
        let work: @MainActor () -> Void = { [weak self] in
            guard let self, let value = self.buffer.takePendingValue() else { return }
            self.lastDeliveredValue = value
            self.pendingDelivery = nil
            #if DEBUG
            self.deliveredCount += 1
            #endif
            deliver(value)
        }
        switch delivery {
        case .mainRunLoopTurn:
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        #if DEBUG
        case .manual:
            pendingDelivery = work
        #endif
        }
    }

    func cancel() {
        buffer.cancel()
        lastDeliveredValue = nil
        pendingDelivery = nil
    }

    #if DEBUG
    func flushPendingDeliveryForTesting() {
        pendingDelivery?()
        pendingDelivery = nil
    }
    #endif
}
