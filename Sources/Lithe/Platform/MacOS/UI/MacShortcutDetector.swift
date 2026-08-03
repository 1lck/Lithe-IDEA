import AppKit
import Foundation

final class MacShortcutDetectorFactory: ShortcutDetectorFactory {
    func make(onDoubleTap: @escaping @MainActor () -> Void) -> any ShortcutDetector {
        MacDoubleShiftDetector(onDoubleTap: onDoubleTap)
    }
}

/// Detects two Shift presses within a short interval for Search Everywhere.
private final class MacDoubleShiftDetector: ShortcutDetector, @unchecked Sendable {
    private static let threshold: TimeInterval = 0.35
    private var shiftWasDown = false
    private var lastShiftPress = Date.distantPast
    private let onDoubleTap: @MainActor () -> Void
    private var monitor: Any?

    init(onDoubleTap: @escaping @MainActor () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isShiftDown = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.shift)
            guard let self else { return event }
            if isShiftDown && !self.shiftWasDown {
                let now = Date()
                if now.timeIntervalSince(self.lastShiftPress) < Self.threshold {
                    self.lastShiftPress = .distantPast
                    Task { @MainActor in
                        self.onDoubleTap()
                    }
                } else {
                    self.lastShiftPress = now
                }
            }
            self.shiftWasDown = isShiftDown
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
