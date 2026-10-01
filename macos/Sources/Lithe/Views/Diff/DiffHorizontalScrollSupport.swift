import AppKit
import SwiftUI

/// One IDEA-style horizontal scroller controls both fixed-width diff panes.
/// The panes keep their on-screen geometry while their code content shares the
/// same pixel offset.
struct DiffHorizontalScroller: NSViewRepresentable {
    @Binding var offset: CGFloat
    let viewportWidth: CGFloat
    let contentWidth: CGFloat

    func makeNSView(context: Context) -> DiffHorizontalScrollerView {
        let view = DiffHorizontalScrollerView()
        view.clipsToBounds = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.scrollBar)
        view.setAccessibilityOrientation(.horizontal)
        view.setAccessibilityLabel("Synchronized diff horizontal scroll")
        return view
    }
    func updateNSView(_ view: DiffHorizontalScrollerView, context: Context) {
        view.offset = offset; view.viewportWidth = viewportWidth; view.contentWidth = contentWidth
        view.onScroll = { offset = $0 }
        view.isHidden = view.maximumOffset <= 0.5
        view.needsDisplay = true
    }
}

/// A native hit surface stays above the native code columns. A SwiftUI clear
/// gesture overlay can paint its thumb while mouse events still hit NSTextView.
final class DiffHorizontalScrollerView: NSView {
    var offset: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
    var onScroll: ((CGFloat) -> Void)?
    private var dragStart: (windowX: CGFloat, offset: CGFloat, travel: CGFloat)?
    private var scheduler = LitheDragUpdateScheduler()
    private var tracking: NSTrackingArea?
    private var hovering = false
    var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    var knobRect: NSRect {
        let track = max(0, bounds.width - 12)
        let width = min(track, max(46, track * min(1, viewportWidth / max(1, contentWidth))))
        return NSRect(x: 6 + (maximumOffset > 0 ? offset / maximumOffset * (track - width) : 0),
            y: 0, width: width, height: bounds.height)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(LitheTheme.Diff.background).setFill(); bounds.intersection(dirtyRect).fill()
        LitheScrollBarStyle.paint(bounds: bounds, knob: knobRect, role: .editor,
            dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            hover: hovering || dragStart != nil ? 1 : 0)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if knobRect.contains(point) {
            dragStart = (event.locationInWindow.x, offset, max(0, bounds.width - 12 - knobRect.width))
        } else {
            apply(offset + (point.x < knobRect.minX ? -1 : 1) * viewportWidth * 0.9)
        }
        needsDisplay = true
    }
    private func value(for event: NSEvent) -> CGFloat? {
        guard let dragStart, dragStart.travel > 0 else { return nil }
        return min(max(dragStart.offset + (event.locationInWindow.x - dragStart.windowX)
            / dragStart.travel * maximumOffset, 0), maximumOffset)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let value = value(for: event) else { return }
        scheduler.submit(value) { [weak self] in self?.apply($0) }
    }
    override func mouseUp(with event: NSEvent) {
        scheduler.cancel()
        if let value = value(for: event) { apply(value) }
        dragStart = nil; needsDisplay = true
    }
    private func apply(_ value: CGFloat) {
        offset = min(max(value, 0), maximumOffset)
        onScroll?(offset); needsDisplay = true
    }
    override func accessibilityValue() -> Any? { maximumOffset > 0 ? offset / maximumOffset : 0 }
    override func setAccessibilityValue(_ value: Any?) {
        if let value = value as? NSNumber { apply(CGFloat(value.doubleValue) * maximumOffset) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { scheduler.cancel(); dragStart = nil }
    }
}

/// Observes horizontal trackpad/wheel gestures over the diff without becoming
/// a hit-test surface, so text selection and vertical scrolling keep working.
struct DiffHorizontalScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        private weak var view: NSView?
        nonisolated(unsafe) private var eventMonitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            self.view = view
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window else {
                    return event
                }

                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point),
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                      abs(event.scrollingDeltaX) > 0.01 else {
                    return event
                }

                self.onScroll(-event.scrollingDeltaX)
                return nil
            }
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }
}
