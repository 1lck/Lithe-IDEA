import AppKit
import SwiftUI

/// A window owns Find before the workspace keymap. The native target also works
/// when no project window (and therefore no workspace shortcut detector) exists.
struct MacWindowFindCommand: NSViewRepresentable {
    let focus: () -> Void
    func makeNSView(context: Context) -> MacWindowFindTarget { MacWindowFindTarget() }
    func updateNSView(_ view: MacWindowFindTarget, context: Context) { view.focus = focus }
    static func dismantleNSView(_ view: MacWindowFindTarget, coordinator: ()) { view.stop() }
}

final class MacWindowFindTarget: NSView {
    var focus: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return Self.handle(event) ? nil : event
        }
    }
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "f",
              let window = event.window, window.attachedSheet == nil,
              !MacShortcutInputPolicy.shouldDeferToMarkedText(window.firstResponder),
              let root = window.contentView else { return false }
        func target(in view: NSView) -> MacWindowFindTarget? {
            if let target = view as? MacWindowFindTarget { return target }
            for child in view.subviews { if let found = target(in: child) { return found } }
            return nil
        }
        guard let target = target(in: root), let focus = target.focus else { return false }
        focus()
        return true
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
