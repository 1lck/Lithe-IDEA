import AppKit
import SwiftUI

struct ProjectReplaceCornerHandle: NSViewRepresentable {
    let corner: ProjectReplacePanelGeometry.Corner
    let onStart: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: (CGSize) -> Void

    func makeNSView(context: Context) -> ProjectReplaceCornerHandleView {
        ProjectReplaceCornerHandleView()
    }

    func updateNSView(_ view: ProjectReplaceCornerHandleView, context: Context) {
        view.corner = corner
        view.onStart = onStart
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: ProjectReplaceCornerHandleView, coordinator: ()) {
        view.endTracking()
    }
}

/// Owns the hit target and cursor for the whole drag, even outside the moving corner.
final class ProjectReplaceCornerHandleView: NSView {
    var corner = ProjectReplacePanelGeometry.Corner.topLeading {
        didSet { if corner != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var onStart: (() -> Void)?
    var onChange: ((CGSize) -> Void)?
    var onEnd: ((CGSize) -> Void)?
    private var tracking: NSTrackingArea?
    private var start: NSPoint?
    private var lastTranslation = CGSize.zero
    private weak var trackingWindow: NSWindow?

    var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            switch corner {
            case .topLeading: return .frameResize(position: .topLeft, directions: .all)
            case .topTrailing: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeading: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomTrailing: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        return corner.isLeading == corner.isTop ? Self.northwestSoutheast : Self.northeastSouthwest
    }

    private static let northwestSoutheast = diagonalCursor("arrow.up.left.and.arrow.down.right")
    private static let northeastSouthwest = diagonalCursor("arrow.up.right.and.arrow.down.left")

    private static func diagonalCursor(_ name: String) -> NSCursor {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Resize diagonally")!
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: resizeCursor)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }
    override func mouseExited(with event: NSEvent) {
        if start != nil { resizeCursor.set() }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        endTracking()
        trackingWindow = window
        start = window.convertPoint(toScreen: event.locationInWindow)
        lastTranslation = .zero
        // Resizing invalidates cursor rectangles; AppKit must not restore the arrow mid-drag.
        window.disableCursorRects()
        resizeCursor.set()
        onStart?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let translation = translation(event) else { return }
        resizeCursor.set()
        guard abs(translation.width - lastTranslation.width) >= 1 ||
              abs(translation.height - lastTranslation.height) >= 1 else { return }
        lastTranslation = translation
        onChange?(translation)
    }
    override func mouseUp(with event: NSEvent) {
        guard let translation = translation(event) else { return }
        onEnd?(translation)
        endTracking()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endTracking() }
        super.viewWillMove(toWindow: newWindow)
    }
    func endTracking() {
        let owner = trackingWindow
        if start != nil { owner?.enableCursorRects() }
        start = nil
        trackingWindow = nil
        owner?.invalidateCursorRects(for: self)
    }
    private func translation(_ event: NSEvent) -> CGSize? {
        guard let start, let window = trackingWindow else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return CGSize(width: point.x - start.x, height: start.y - point.y)
    }
}
