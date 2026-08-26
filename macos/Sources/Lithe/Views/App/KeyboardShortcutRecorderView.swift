import AppKit
import SwiftUI

struct KeyboardShortcutRecorderView: View {
    @ObservedObject var feature: KeyboardShortcutFeatureModel
    let commandID: String
    let onRecorded: (KeyboardShortcutBinding) -> Void
    let onInvalid: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "keyboard")
            Text("Press shortcut…")
            Spacer(minLength: 8)
            Text("Esc")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(LitheTheme.accent)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(LitheTheme.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(LitheTheme.accent.opacity(0.7), lineWidth: 1)
        }
        .background(
            KeyboardShortcutCaptureMonitor(
                onRecorded: onRecorded,
                onInvalid: onInvalid,
                onCancel: onCancel
            )
            .frame(width: 0, height: 0)
        )
        .onAppear { feature.beginRecording(commandID: commandID) }
        .onDisappear { feature.endRecording(commandID: commandID) }
    }
}

private struct KeyboardShortcutCaptureMonitor: NSViewRepresentable {
    let onRecorded: (KeyboardShortcutBinding) -> Void
    let onInvalid: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onRecorded: onRecorded,
            onInvalid: onInvalid,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRecorded = onRecorded
        context.coordinator.onInvalid = onInvalid
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private static let doubleTapThreshold: TimeInterval = 0.35
        var onRecorded: (KeyboardShortcutBinding) -> Void
        var onInvalid: () -> Void
        var onCancel: () -> Void
        private var keyMonitor: Any?
        private var flagsMonitor: Any?
        private var shiftWasDown = false
        private var lastShiftPress = Date.distantPast

        init(
            onRecorded: @escaping (KeyboardShortcutBinding) -> Void,
            onInvalid: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onRecorded = onRecorded
            self.onInvalid = onInvalid
            self.onCancel = onCancel
        }

        func start() {
            guard keyMonitor == nil, flagsMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.onCancel()
                    return nil
                }
                guard let binding = MacKeyboardShortcutEventMapper.binding(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifierFlags: event.modifierFlags
                ) else {
                    return nil
                }
                guard binding.isAssignable else {
                    self.onInvalid()
                    return nil
                }
                self.onRecorded(binding)
                return nil
            }

            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let isShiftDown = flags.contains(.shift)
                defer { self.shiftWasDown = isShiftDown }
                guard isShiftDown, !self.shiftWasDown,
                      flags.intersection([.command, .control, .option]).isEmpty else { return event }
                let now = Date()
                guard now.timeIntervalSince(self.lastShiftPress) < Self.doubleTapThreshold else {
                    self.lastShiftPress = now
                    return event
                }
                self.lastShiftPress = .distantPast
                self.onRecorded(.doubleTap(.shift))
                return nil
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
        }

        deinit {
            stop()
        }
    }
}
