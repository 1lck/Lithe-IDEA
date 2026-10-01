import AppKit
import SwiftUI

/// Routes clipboard shortcuts only after a pointer interaction inside the tree.
/// A click elsewhere, or a keyboard focus change after the click, returns
/// keyboard ownership to the focused view.
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
    // The tree has no focusable view, and opening a file may move focus to the
    // editor asynchronously. The responder seen by the first key after a tree
    // click is therefore the baseline; any later change came from the keyboard.
    private var hasKeyboardResponder = false
    private weak var keyboardResponder: NSResponder?
    private weak var responderAtClick: NSResponder?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// Returns `nil` when the tree consumed the event.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window else { return event }
        guard (event.window ?? NSApp.keyWindow) === window else {
            releaseKeyboard()
            return event
        }
        if event.type != .keyDown {
            let point = event.window == nil
                ? window.convertPoint(fromScreen: NSEvent.mouseLocation)
                : event.locationInWindow
            releaseKeyboard()
            ownsKeyboard = !isHiddenOrHasHiddenAncestor && bounds.contains(convert(point, from: nil))
            responderAtClick = Self.focusOwner(window.firstResponder)
            return event
        }
        guard ownsKeyboard, !isHiddenOrHasHiddenAncestor else { return event }
        let responder = Self.focusOwner(window.firstResponder)
        // A text field focused after the tree click, such as Search Everywhere,
        // keeps standard text shortcuts. Some panels open from modifier-only
        // gestures, so their field editor can be the first key responder.
        if responder is NSTextField, responder !== responderAtClick {
            releaseKeyboard()
            return event
        }
        if !hasKeyboardResponder {
            hasKeyboardResponder = true
            keyboardResponder = responder
        } else if keyboardResponder !== responder {
            releaseKeyboard()
            return event
        }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copyItems?()
        case "v": pasteItems?()
        case "a": selectAllItems?()
        default: return event
        }
        return nil
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        releaseKeyboard()
    }

    /// Text fields in one window share a field editor; compare the edited field.
    private static func focusOwner(_ responder: NSResponder?) -> NSResponder? {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return responder }
        return editor.delegate as? NSTextField ?? editor
    }

    private func releaseKeyboard() {
        ownsKeyboard = false
        hasKeyboardResponder = false
        keyboardResponder = nil
        responderAtClick = nil
    }
}
