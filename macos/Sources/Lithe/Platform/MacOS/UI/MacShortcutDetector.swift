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
    func make(onCommand: @escaping @MainActor @Sendable (String) -> Void) -> any ShortcutDetector {
        MacShortcutDetector(onCommand: onCommand)
    }
}

enum MacKeyboardShortcutEventMapper {
    private static let specialKeys: [UInt16: String] = [
        36: "return",
        48: "tab",
        49: "space",
        51: "delete",
        64: "f17",
        79: "f18",
        80: "f19",
        90: "f20",
        96: "f5",
        97: "f6",
        98: "f7",
        99: "f3",
        100: "f8",
        101: "f9",
        103: "f11",
        105: "f13",
        106: "f16",
        107: "f14",
        109: "f10",
        111: "f12",
        113: "f15",
        118: "f4",
        120: "f2",
        122: "f1",
        123: "left",
        124: "right",
        125: "down",
        126: "up"
    ]

    static func binding(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> KeyboardShortcutBinding? {
        let key: String
        if let specialKey = specialKeys[keyCode] {
            key = specialKey
        } else if let charactersIgnoringModifiers,
                  charactersIgnoringModifiers.count == 1 {
            key = charactersIgnoringModifiers.lowercased()
        } else {
            return nil
        }

        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyboardShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return .keyPress(key: key, modifiers: modifiers)
    }
}

enum MacKeyboardShortcutMatcher {
    static func commandID(
        for binding: KeyboardShortcutBinding,
        registrations: [KeyboardShortcutRegistration]
    ) -> String? {
        registrations.first { $0.bindings.contains(binding) }?.commandID
    }
}

/// Matches ordinary key presses and double-modifier taps for application commands.
private final class MacShortcutDetector: ShortcutDetector, @unchecked Sendable {
    private static let doubleTapThreshold: TimeInterval = 0.35

    private var registrations: [KeyboardShortcutRegistration] = []
    private var isSuspended = false
    private var doubleShiftRecognizer: DoubleShiftGestureRecognizer
    private let onCommand: @MainActor @Sendable (String) -> Void
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    init(onCommand: @escaping @MainActor @Sendable (String) -> Void) {
        self.onCommand = onCommand
        doubleShiftRecognizer = DoubleShiftGestureRecognizer(
            threshold: Self.doubleTapThreshold
        )
    }

    func update(registrations: [KeyboardShortcutRegistration]) {
        self.registrations = registrations
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            resetDoubleShiftRecognizer()
        }
    }

    func start() {
        guard keyMonitor == nil, flagsMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.doubleShiftRecognizer.handleKeyDown()
            guard !self.isSuspended,
                  let binding = MacKeyboardShortcutEventMapper.binding(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifierFlags: event.modifierFlags
                  ),
                  let commandID = MacKeyboardShortcutMatcher.commandID(
                    for: binding,
                    registrations: self.registrations
                  ) else {
                return event
            }
            Task { @MainActor in
                self.onCommand(commandID)
            }
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, !self.isSuspended else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let shouldTrigger = self.doubleShiftRecognizer.handleFlagsChanged(
                isShiftDown: modifiers.contains(.shift),
                hasOtherModifiers: !modifiers.intersection([
                    .command, .control, .option, .function
                ]).isEmpty,
                timestamp: event.timestamp
            )
            guard shouldTrigger,
                  let commandID = MacKeyboardShortcutMatcher.commandID(
                    for: .doubleTap(.shift),
                    registrations: self.registrations
                  ) else {
                return event
            }
            Task { @MainActor in
                self.onCommand(commandID)
            }
            return event
        }
    }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        resetDoubleShiftRecognizer()
    }

    private func resetDoubleShiftRecognizer() {
        doubleShiftRecognizer = DoubleShiftGestureRecognizer(
            threshold: Self.doubleTapThreshold
        )
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
