import AppKit
import SwiftUI

/// AppKit drag source for terminal tabs; SwiftUI's public payload would be inserted as editor text.
struct TerminalTabInteraction: NSViewRepresentable {
    let sessionID: UUID
    let title: String
    let activate: () -> Void

    func makeNSView(context: Context) -> TerminalTabInteractionView {
        let view = TerminalTabInteractionView()
        view.sessionID = sessionID
        view.title = title
        view.activate = activate
        return view
    }

    func updateNSView(_ view: TerminalTabInteractionView, context: Context) {
        view.sessionID = sessionID
        view.title = title
        view.activate = activate
        view.toolTip = title
    }
}

final class TerminalTabInteractionView: NSView, NSDraggingSource {
    var sessionID: UUID?
    var title = ""
    var activate: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    /// Only left-button gestures belong to the tab; hover and context menus stay with SwiftUI underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        activate?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let sessionID, window != nil else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) >= 4 else { return }
        mouseDownEvent = nil

        let item = NSPasteboardItem()
        item.setString(sessionID.uuidString, forType: TerminalTabDragPayload.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let location = convert(event.locationInWindow, from: nil)
        let fallback = NSImage(size: NSSize(width: 24, height: 24))
        let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? fallback
        let frame = NSRect(x: location.x - 12, y: location.y - 12, width: 24, height: 24)
        draggingItem.setDraggingFrame(frame, contents: image)
        TerminalTabDragPayload.beginDrag(sessionID)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        TerminalTabDragPayload.endDrag()
    }
}

/// Covers only the tool canvas; the toolbar retains its per-tab insertion targets.
struct TerminalToolDropOverlay: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> TerminalToolDropOverlayView {
        let view = TerminalToolDropOverlayView()
        view.model = model
        return view
    }

    func updateNSView(_ view: TerminalToolDropOverlayView, context: Context) {
        view.model = model
    }
}

final class TerminalToolDropOverlayView: NSView {
    var model: AppModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TerminalTabDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard TerminalTabDragPayload.isDragging,
              let sessionID = TerminalTabDragPayload.activeSessionID,
              model?.editorTabOrderFeature.contains(.terminal(sessionID)) == true else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditorTerminal(sender) ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditorTerminal(sender) ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isEditorTerminal(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sessionID = TerminalTabDragPayload.sessionID(from: sender.draggingPasteboard),
              let model, model.editorTabOrderFeature.contains(.terminal(sessionID)) else { return false }
        model.moveTerminalToTool(sessionID)
        return true
    }

    private func isEditorTerminal(_ sender: NSDraggingInfo) -> Bool {
        guard let sessionID = TerminalTabDragPayload.sessionID(from: sender.draggingPasteboard),
              let model else { return false }
        return model.editorTabOrderFeature.contains(.terminal(sessionID))
    }
}

/// Empty editor area needs its own destination before any group container exists.
struct TerminalEmptyEditorDropOverlay: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> TerminalEmptyEditorDropOverlayView {
        let view = TerminalEmptyEditorDropOverlayView()
        view.model = model
        return view
    }

    func updateNSView(_ view: TerminalEmptyEditorDropOverlayView, context: Context) {
        view.model = model
    }
}

final class TerminalEmptyEditorDropOverlayView: NSView {
    var model: AppModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TerminalTabDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard TerminalTabDragPayload.isDragging,
              let sessionID = TerminalTabDragPayload.activeSessionID,
              model?.editorTabOrderFeature.contains(.terminal(sessionID)) == false else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isToolTerminal(sender) ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isToolTerminal(sender) ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isToolTerminal(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sessionID = TerminalTabDragPayload.sessionID(from: sender.draggingPasteboard),
              let model, !model.editorTabOrderFeature.contains(.terminal(sessionID)) else { return false }
        return model.moveTerminalToEditor(sessionID, into: nil, side: .center)
    }

    private func isToolTerminal(_ sender: NSDraggingInfo) -> Bool {
        guard let sessionID = TerminalTabDragPayload.sessionID(from: sender.draggingPasteboard),
              let model else { return false }
        return !model.editorTabOrderFeature.contains(.terminal(sessionID))
    }
}

/// AppKit drop target above the editor surface. Monaco consumes drags inside its WebView.
/// The view is hit-testable only during a terminal drag and defers tab strips to SwiftUI.
struct TerminalEditorDropOverlay: NSViewRepresentable {
    let drag: EditorGroupDragState
    let model: AppModel

    func makeNSView(context: Context) -> TerminalEditorDropOverlayView {
        let view = TerminalEditorDropOverlayView()
        view.drag = drag
        view.model = model
        return view
    }

    func updateNSView(_ view: TerminalEditorDropOverlayView, context: Context) {
        view.drag = drag
        view.model = model
    }
}

final class TerminalEditorDropOverlayView: NSView {
    var drag: EditorGroupDragState?
    var model: AppModel?
    private var currentTarget: EditorGroupDragState.Target?

    /// SwiftUI records group and tab frames in a top-left coordinate space.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TerminalTabDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard TerminalTabDragPayload.isDragging else { return nil }
        // Tab strips keep their own reorder/move targets.
        if let drag, let superview {
            let local = convert(point, from: superview)
            if drag.tabFrames.values.contains(where: { $0.contains(local) }) {
                return nil
            }
        }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sessionID(from: sender) != nil else { return [] }
        drag?.begin()
        return update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        currentTarget = nil
        drag?.finish()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        currentTarget != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sessionID = sessionID(from: sender), let target = currentTarget else {
            drag?.finish()
            return false
        }
        currentTarget = nil
        drag?.finish()
        return model?.moveTerminalToEditor(sessionID, into: target.group, side: target.side) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        currentTarget = nil
        drag?.finish()
    }

    private func sessionID(from sender: NSDraggingInfo) -> UUID? {
        TerminalTabDragPayload.sessionID(from: sender.draggingPasteboard)
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let sessionID = sessionID(from: sender), let drag, let model else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let item = EditorTabItem.terminal(sessionID)
        let source = model.editorTabOrderFeature.group(containing: item)
        guard let target = drag.destination(at: point, sourceGroup: source) else {
            drag.updateTarget(nil)
            currentTarget = nil
            return []
        }
        if model.editorTabOrderFeature.contains(item),
           !model.editorTabOrderFeature.canDrop(item, into: target.group, side: target.side) {
            drag.updateTarget(nil)
            currentTarget = nil
            return []
        }
        drag.updateTarget(target)
        currentTarget = target
        return .move
    }
}
