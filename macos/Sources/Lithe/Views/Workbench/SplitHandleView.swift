import AppKit
import os
import SwiftUI

enum LitheSplitAxis {
    case horizontal
    case vertical
}

struct SplitHandleView: View {
    // Keep the hit target wider than the visible divider so resizing does not
    // depend on landing on a single pixel row or column.
    static let thickness: CGFloat = 5
    static let hitThickness: CGFloat = 10

    let axis: LitheSplitAxis
    let leadingBackground: Color
    let trailingBackground: Color
    let showsIdleDivider: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragScheduler = LitheDragUpdateScheduler()
    @State private var dragSignpost: LitheSignpost.State?

    init(
        axis: LitheSplitAxis,
        leadingBackground: Color = .clear,
        trailingBackground: Color = .clear,
        showsIdleDivider: Bool = true,
        onDragStarted: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping (CGFloat) -> Void
    ) {
        self.axis = axis
        self.leadingBackground = leadingBackground
        self.trailingBackground = trailingBackground
        self.showsIdleDivider = showsIdleDivider
        self.onDragStarted = onDragStarted
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        ZStack {
            trackBackground
            Color.clear
            dividerLine
        }
        .frame(
            width: axis == .horizontal ? Self.hitThickness : nil,
            height: axis == .vertical ? Self.hitThickness : nil
        )
        .frame(
            maxWidth: axis == .vertical ? .infinity : nil,
            maxHeight: axis == .horizontal ? .infinity : nil
        )
        .overlay {
            SplitHandleInteraction(
                axis: axis,
                onHoverChanged: { isInside in
                    guard isInside != isHovering else { return }
                    isHovering = isInside
                },
                onDragStarted: {
                    isDragging = true
                    dragSignpost = LitheSignpost.begin("split.drag")
                    onDragStarted()
                },
                onDragChanged: { currentTranslation in
                    // Keep geometry changes coalesced and local to the split container.
                    dragScheduler.submit(currentTranslation) { translation in
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            onDragChanged(translation)
                        }
                    }
                },
                onDragEnded: { finalTranslation in
                    dragScheduler.cancel()
                    isDragging = false
                    if let dragSignpost {
                        LitheSignpost.end("split.drag", dragSignpost)
                        self.dragSignpost = nil
                    }
                    onDragEnded(finalTranslation)
                }
            )
        }
        .onDisappear {
            dragScheduler.cancel()
            if let dragSignpost {
                LitheSignpost.end("split.drag", dragSignpost)
                self.dragSignpost = nil
            }
        }
        // Reserve a compact gap while the centered hit surface extends into both panes.
        .frame(
            width: axis == .horizontal ? Self.thickness : nil,
            height: axis == .vertical ? Self.thickness : nil
        )
        .zIndex(1)
        .help(axis == .horizontal ? "Drag left or right to resize" : "Drag up or down to resize")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axis == .horizontal ? "Horizontal pane resize handle" : "Vertical pane resize handle")
    }

    @ViewBuilder
    private var trackBackground: some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                leadingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                trailingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                leadingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                trailingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var dividerLine: some View {
        if showsIdleDivider {
            if axis == .horizontal {
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

}

private struct SplitHandleInteraction: NSViewRepresentable {
    let axis: LitheSplitAxis
    let onHoverChanged: (Bool) -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> SplitHandleInteractionView {
        let view = SplitHandleInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SplitHandleInteractionView, context: Context) {
        view.axis = axis
        view.onHoverChanged = onHoverChanged
        view.onDragStarted = onDragStarted
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

/// The native hit target owns both cursor tracking and drag delivery. A cursor
/// background that returns nil from hitTest leaves NSHostingView in charge of
/// the pointer and lets it overwrite the resize cursor after native editor exit.
final class SplitHandleInteractionView: NSView {
    var axis: LitheSplitAxis = .horizontal {
        didSet {
            guard axis != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHoverChanged: ((Bool) -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?
    private var tracking: NSTrackingArea?
    private var dragStartPoint: NSPoint?

    var resizeCursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dragStartPoint = nil }
    }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseMoved(with event: NSEvent) { resizeCursor.set() }

    override func mouseEntered(with event: NSEvent) {
        resizeCursor.set()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Screen coordinates do not move when the divider resizes either pane.
        dragStartPoint = window.convertPoint(toScreen: event.locationInWindow)
        resizeCursor.set()
        onDragStarted?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let translation = translation(for: event) else { return }
        resizeCursor.set()
        onDragChanged?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let translation = translation(for: event) else { return }
        dragStartPoint = nil
        onDragEnded?(translation)
    }

    private func translation(for event: NSEvent) -> CGFloat? {
        guard let window, let dragStartPoint else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        // Match SwiftUI's downward-positive vertical translation contract.
        return axis == .horizontal ? point.x - dragStartPoint.x : dragStartPoint.y - point.y
    }
}
