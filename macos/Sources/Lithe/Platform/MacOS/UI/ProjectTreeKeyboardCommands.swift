import AppKit
import SwiftUI

/// Routes clipboard shortcuts only after a pointer interaction inside the tree.
/// A click in the editor or another window returns keyboard ownership to it.
struct ProjectTreeKeyboardCommands: NSViewRepresentable {
    let copy: () -> Void
    let paste: () -> Void
    let selectAll: () -> Void

    func makeNSView(context: Context) -> ProjectTreeKeyboardCommandView {
        let view = ProjectTreeKeyboardCommandView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProjectTreeKeyboardCommandView, context: Context) {
        view.copyItems = copy
        view.pasteItems = paste
        view.selectAllItems = selectAll
    }

    static func dismantleNSView(_ view: ProjectTreeKeyboardCommandView, coordinator: ()) {
        view.removeMonitor()
    }
}

final class ProjectTreeKeyboardCommandView: NSView {
    var copyItems: (() -> Void)?
    var pasteItems: (() -> Void)?
    var selectAllItems: (() -> Void)?
    private var monitor: Any?
    private var ownsKeyboard = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard (event.window ?? NSApp.keyWindow) === window else {
                self.ownsKeyboard = false
                return event
            }
            if event.type != .keyDown {
                let point = event.window == nil
                    ? window.convertPoint(fromScreen: NSEvent.mouseLocation)
                    : event.locationInWindow
                self.ownsKeyboard = !self.isHiddenOrHasHiddenAncestor
                    && self.bounds.contains(self.convert(point, from: nil))
                return event
            }
            guard self.ownsKeyboard, !self.isHiddenOrHasHiddenAncestor,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": self.copyItems?()
            case "v": self.pasteItems?()
            case "a": self.selectAllItems?()
            default: return event
            }
            return nil
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ownsKeyboard = false
    }
}
