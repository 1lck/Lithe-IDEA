import AppKit
import SwiftUI

/// Where each editor tab currently sits, recorded from layout.
///
/// Deliberately a reference box held as `@State` rather than `@State` storage of
/// the dictionary itself. The frames are only read when a drag or drop begins,
/// but the preference that reports them fires on *every* layout pass — including
/// every frame of a pane resize. Storing them as view state made each of those
/// passes re-evaluate the whole editor area; a reference box records them
/// without invalidating anything.
///
/// Follows the same pattern as `EditorViewportStore` and `LithePointerCursor`.
@MainActor
final class EditorTabFrameStore {
    private(set) var frames: [EditorTabItem: CGRect] = [:]

    func update(_ frames: [EditorTabItem: CGRect]) {
        self.frames = frames
    }

    subscript(item: EditorTabItem) -> CGRect? {
        frames[item]
    }
}

/// Snapshot once, then move only a non-activating native window while dragging.
/// The preview must not be clipped by the tab strip's horizontal scroll view.
@MainActor
final class EditorTabDragPreviewStore {
    private struct Anchor {
        weak var view: NSView?
        var frame: (() -> CGRect?)?
        var clicked: (() -> Void)?
        var changed: ((CGSize, CGPoint) -> Void)?
        var ended: ((CGSize, CGPoint) -> Void)?
    }
    private var anchors: [EditorTabItem: Anchor] = [:]
    private(set) var panel: NSPanel?
    private var origin = CGPoint.zero
    private var escapeMonitor: Any?
    private var mouseMonitor: Any?
    private var pressed: (item: EditorTabItem, windowPoint: CGPoint, workspacePoint: CGPoint)?
    private var isMouseDragging = false

    func register(_ view: NSView, for item: EditorTabItem, frame: (() -> CGRect?)? = nil,
                  clicked: (() -> Void)? = nil, changed: ((CGSize, CGPoint) -> Void)? = nil, ended: ((CGSize, CGPoint) -> Void)? = nil) {
        anchors[item] = Anchor(view: view, frame: frame, clicked: clicked, changed: changed, ended: ended)
        guard changed != nil, view.window != nil, mouseMonitor == nil else { return }
        // One monitor per tab group. SwiftUI drag recognizers can miss a fast jump into a native editor.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                self.pressed = nil; self.isMouseDragging = false
                guard !event.modifierFlags.contains(.control), let entry = self.anchors.first(where: {
                    guard let view = $0.value.view, view.window === event.window, $0.value.changed != nil else { return false }
                    if case .terminal = $0.key { return false }
                    let point = view.convert(event.locationInWindow, from: nil)
                    // Leave the close-button slot to the existing button, including inactive tabs.
                    return !view.isHiddenOrHasHiddenAncestor && view.bounds.intersection(view.visibleRect).contains(point) && point.x < view.bounds.maxX - 24
                }), let view = entry.value.view, let frame = entry.value.frame?() else { return event }
                let local = view.convert(event.locationInWindow, from: nil)
                self.pressed = (entry.key, event.locationInWindow,
                    CGPoint(x: frame.minX + local.x, y: frame.minY + local.y))
                return nil
            }
            guard let pressed = self.pressed, let anchor = self.anchors[pressed.item],
                  anchor.view?.window === event.window else { return event }
            let translation = CGSize(width: event.locationInWindow.x - pressed.windowPoint.x,
                                     height: pressed.windowPoint.y - event.locationInWindow.y)
            let point = CGPoint(x: pressed.workspacePoint.x + translation.width,
                                y: pressed.workspacePoint.y + translation.height)
            if event.type == .leftMouseDragged {
                guard self.isMouseDragging || hypot(translation.width, translation.height) >= 8 else { return nil }
                self.isMouseDragging = true
                anchor.changed?(translation, point)
                return nil
            }
            self.pressed = nil
            guard self.isMouseDragging else {
                if let view = anchor.view, !view.isHiddenOrHasHiddenAncestor,
                   view.bounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil)) {
                    anchor.clicked?()
                }
                return nil
            }
            self.isMouseDragging = false
            anchor.ended?(translation, point)
            return nil
        }
    }

    func unregister(_ view: NSView, for item: EditorTabItem) {
        if anchors[item]?.view === view { anchors[item] = nil }
    }

    func stopCapturing() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        pressed = nil; isMouseDragging = false; anchors = [:]
        finish()
    }

    func begin(_ item: EditorTabItem, image suppliedImage: NSImage? = nil, onCancel: @escaping () -> Void) {
        finish()
        guard let anchor = anchors[item]?.view, let window = anchor.window,
              let content = window.contentView else { return }
        let rect = anchor.convert(anchor.bounds.insetBy(dx: 4, dy: 4), to: content)
        guard rect.width > 0, rect.height > 0 else { return }
        let image: NSImage
        if let suppliedImage { image = suppliedImage }
        else {
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return }
            content.cacheDisplay(in: rect, to: bitmap)
            image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
        }
        var screenFrame = window.convertToScreen(content.convert(rect, to: nil))
        screenFrame.size = image.size
        let panel = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("lithe.editor-tab-drag-preview")
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.alphaValue = 0.9 // DockManagerImpl.DragImageDialog alpha mode ratio 0.1.
        let view = NSImageView(frame: CGRect(origin: .zero, size: image.size))
        view.image = image
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        panel.contentView = view
        origin = screenFrame.origin
        self.panel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            onCancel()
            return nil
        }
    }

    func move(by translation: CGSize) {
        panel?.setFrameOrigin(CGPoint(x: origin.x + translation.width, y: origin.y - translation.height))
    }

    func finish() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.contentView = nil
        panel.close()
        self.panel = nil
    }
}

struct EditorTabDragPreviewAnchor: NSViewRepresentable {
    let item: EditorTabItem
    let store: EditorTabDragPreviewStore
    var frame: (() -> CGRect?)? = nil
    var clicked: (() -> Void)? = nil
    var changed: ((CGSize, CGPoint) -> Void)? = nil
    var ended: ((CGSize, CGPoint) -> Void)? = nil
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.item = item; view.store = store; view.frameReader = frame; view.clicked = clicked; view.changed = changed; view.ended = ended
        view.record()
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        if let item = view.item { view.store?.unregister(view, for: item) }
    }
    final class AnchorView: NSView {
        var item: EditorTabItem?
        weak var store: EditorTabDragPreviewStore?
        var frameReader: (() -> CGRect?)?
        var clicked: (() -> Void)?
        var changed: ((CGSize, CGPoint) -> Void)?
        var ended: ((CGSize, CGPoint) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); record() }
        func record() {
            if let item { store?.register(self, for: item, frame: frameReader, clicked: clicked, changed: changed, ended: ended) }
        }
    }
}
