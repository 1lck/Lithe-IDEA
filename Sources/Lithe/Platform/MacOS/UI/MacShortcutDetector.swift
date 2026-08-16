import AppKit
import Foundation
import SwiftUI

extension View {
    func macReturnKeyHandler(
        isEnabled: Bool,
        action: @escaping (_ isShiftPressed: Bool) -> Void
    ) -> some View {
        background(
            MacReturnKeyMonitor(isEnabled: isEnabled, action: action)
                .frame(width: 0, height: 0)
        )
    }
}

private struct MacReturnKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let action: (_ isShiftPressed: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, action: action)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var isEnabled: Bool
        var action: (_ isShiftPressed: Bool) -> Void
        private var monitor: Any?

        init(isEnabled: Bool, action: @escaping (_ isShiftPressed: Bool) -> Void) {
            self.isEnabled = isEnabled
            self.action = action
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled, event.keyCode == 36 || event.keyCode == 76 else {
                    return event
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return event }
                self.action(modifiers.contains(.shift))
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stop()
        }
    }
}

final class MacShortcutDetectorFactory: ShortcutDetectorFactory {
    func make(onDoubleTap: @escaping @MainActor () -> Void) -> any ShortcutDetector {
        MacDoubleShiftDetector(onDoubleTap: onDoubleTap)
    }
}

/// Detects two Shift presses within a short interval for Search Everywhere.
private final class MacDoubleShiftDetector: ShortcutDetector, @unchecked Sendable {
    private static let threshold: TimeInterval = 0.35
    private var recognizer = DoubleShiftGestureRecognizer(threshold: threshold)
    private let onDoubleTap: @MainActor () -> Void
    private var monitor: Any?

    init(onDoubleTap: @escaping @MainActor () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            let shouldTrigger: Bool
            switch event.type {
            case .keyDown:
                self.recognizer.handleKeyDown()
                shouldTrigger = false
            case .flagsChanged:
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                shouldTrigger = self.recognizer.handleFlagsChanged(
                    isShiftDown: modifiers.contains(.shift),
                    hasOtherModifiers: !modifiers.intersection([
                        .command, .control, .option, .function
                    ]).isEmpty,
                    timestamp: event.timestamp
                )
            default:
                shouldTrigger = false
            }
            if shouldTrigger {
                Task { @MainActor in
                    self.onDoubleTap()
                }
            }
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

/// Recognizes two standalone Shift taps while rejecting Shift-modified typing.
struct DoubleShiftGestureRecognizer {
    let threshold: TimeInterval
    private(set) var shiftWasDown = false
    private var currentPressIsStandalone = false
    private var lastStandaloneTap: TimeInterval?

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    mutating func handleKeyDown() {
        currentPressIsStandalone = false
        lastStandaloneTap = nil
    }

    mutating func handleFlagsChanged(
        isShiftDown: Bool,
        hasOtherModifiers: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        if isShiftDown, !shiftWasDown {
            currentPressIsStandalone = !hasOtherModifiers
            shiftWasDown = true
            return false
        }

        if isShiftDown, shiftWasDown {
            if hasOtherModifiers {
                currentPressIsStandalone = false
                lastStandaloneTap = nil
            }
            return false
        }

        if !isShiftDown, shiftWasDown {
            shiftWasDown = false
            defer { currentPressIsStandalone = false }
            guard currentPressIsStandalone, !hasOtherModifiers else {
                lastStandaloneTap = nil
                return false
            }
            if let lastStandaloneTap,
               timestamp - lastStandaloneTap >= 0,
               timestamp - lastStandaloneTap < threshold {
                self.lastStandaloneTap = nil
                return true
            }
            lastStandaloneTap = timestamp
            return false
        }

        if hasOtherModifiers {
            lastStandaloneTap = nil
        }
        return false
    }
}
