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
    private struct Anchor { weak var view: NSView? }
    private var anchors: [EditorTabItem: Anchor] = [:]
    private(set) var panel: NSPanel?
    private var origin = CGPoint.zero
    private var escapeMonitor: Any?

    func register(_ view: NSView, for item: EditorTabItem) { anchors[item] = Anchor(view: view) }

    func begin(_ item: EditorTabItem, onCancel: @escaping () -> Void) {
        finish()
        guard let anchor = anchors[item]?.view, let window = anchor.window,
              let content = window.contentView else { return }
        let rect = anchor.convert(anchor.bounds.insetBy(dx: 4, dy: 4), to: content)
        guard rect.width > 0, rect.height > 0,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        let screenFrame = window.convertToScreen(content.convert(rect, to: nil))
        let panel = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("lithe.editor-tab-drag-preview")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.alphaValue = 0.9 // DockManagerImpl.DragImageDialog alpha mode ratio 0.1.
        let view = NSImageView(frame: CGRect(origin: .zero, size: rect.size))
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
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        store.register(view, for: item)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { store.register(view, for: item) }
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
