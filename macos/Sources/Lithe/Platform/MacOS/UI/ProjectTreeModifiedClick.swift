import AppKit
import SwiftUI

/// Captures ⌘/Shift clicks on a tree row and reads their modifiers from the
/// mouse-down event itself. A SwiftUI Button action runs after that event, when
/// NSApp.currentEvent no longer describes the click.
struct ProjectTreeModifiedClick: NSViewRepresentable {
    let select: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> ProjectTreeModifiedClickView {
        let view = ProjectTreeModifiedClickView()
        view.select = select
        return view
    }

    func updateNSView(_ view: ProjectTreeModifiedClickView, context: Context) {
        view.select = select
    }
}

final class ProjectTreeModifiedClickView: NSView {
    var select: ((NSEvent.ModifierFlags) -> Void)?
    /// The event AppKit is dispatching. Tests substitute the synthesized event,
    /// because pulling it through NSApp's event queue ends the test process.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    /// Plain clicks stay with the Button, and Control-click stays the macOS
    /// secondary click handled by the context menu.
    static func captures(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown
            && !event.modifierFlags.contains(.control)
            && !event.modifierFlags.intersection([.shift, .command]).isEmpty
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = currentEvent(), Self.captures(event) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard Self.captures(event) else { return }
        select?(event.modifierFlags)
    }
}
