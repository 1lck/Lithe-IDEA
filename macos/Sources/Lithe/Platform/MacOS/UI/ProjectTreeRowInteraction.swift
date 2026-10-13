import AppKit
import SwiftUI

/// Native row input keeps a selected group intact until a click or drag is known.
/// File URLs remain interoperable with editor/terminal drops; moves are accepted
/// only from another tree row in this window and workspace.
struct ProjectTreeRowInteraction: NSViewRepresentable {
    let workspaceURL: URL
    var destinationURL: URL?
    var disclosureInset: CGFloat = 0
    let select: (NSEvent.ModifierFlags) -> Void
    let activate: () -> Void
    var doubleClick: () -> Void = {}
    let dragURLs: () -> [URL]
    let move: ([URL], URL) -> Void

    func makeNSView(context: Context) -> ProjectTreeRowInteractionView {
        let view = ProjectTreeRowInteractionView()
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ view: ProjectTreeRowInteractionView, context: Context) {
        view.workspaceURL = workspaceURL
        view.destinationURL = destinationURL
        view.disclosureInset = disclosureInset
        view.select = select
        view.activate = activate
        view.doubleClick = doubleClick
        view.dragURLs = dragURLs
        view.move = move
    }
}

final class ProjectTreeRowInteractionView: NSView, NSDraggingSource {
    var workspaceURL: URL?
    var destinationURL: URL?
    var disclosureInset: CGFloat = 0
    var select: ((NSEvent.ModifierFlags) -> Void)?
    var activate: (() -> Void)?
    var doubleClick: (() -> Void)?
    var dragURLs: (() -> [URL])?
    var move: (([URL], URL) -> Void)?
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    private var mouseDownEvent: NSEvent?
    private var draggedURLs: [URL] = []
    private var draggedWorkspaceURL: URL?
    private weak var draggedWindow: NSWindow?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = currentEvent() else { return super.hitTest(point) }
        guard event.type != .rightMouseDown, !event.modifierFlags.contains(.control) else { return nil }
        let local = convert(point, from: superview)
        // The disclosure button remains a separate click target.
        guard event.type != .leftMouseDown || local.x >= disclosureInset else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        mouseDownEvent = nil
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // Use the down-event modifiers even if the key was released first. A
        // Command-drag must not toggle its starting row out of the selection.
        if !start.modifierFlags.intersection([.command, .shift]).isEmpty {
            select?(start.modifierFlags)
        } else {
            activate?()
            if event.clickCount == 2 { doubleClick?() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent,
              hypot(event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y) >= 4 else { return }
        mouseDownEvent = nil
        let urls = dragURLs?() ?? []
        guard !urls.isEmpty else { return }
        draggedURLs = urls
        draggedWorkspaceURL = workspaceURL
        draggedWindow = window
        let origin = convert(start.locationInWindow, from: nil)
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 24, height: 24)),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedURLs = []
        draggedWorkspaceURL = nil
        draggedWindow = nil
        mouseDownEvent = nil
    }

    private func sources(for sender: NSDraggingInfo) -> [URL]? {
        guard let source = sender.draggingSource as? ProjectTreeRowInteractionView,
              source.draggedWindow != nil, source.draggedWindow === window, source.draggedWorkspaceURL == workspaceURL,
              let destinationURL, !source.draggedURLs.isEmpty,
              source.draggedURLs.allSatisfy({
                  destinationURL != $0 && !destinationURL.path.hasPrefix($0.path + "/")
              }) else { return nil }
        return source.draggedURLs
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sources(for: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sources(for: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sources(for: sender), let destinationURL, let move else { return false }
        move(urls, destinationURL)
        return true
    }
}
