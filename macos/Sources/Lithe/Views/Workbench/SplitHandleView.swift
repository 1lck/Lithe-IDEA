import AppKit
import SwiftUI

enum LitheSplitAxis {
    case horizontal
    case vertical
}

struct SplitHandleView: View {
    // Keep the hit target wider than the visible divider so resizing does not
    // depend on landing on a single pixel row or column.
    static let thickness: CGFloat = 10

    let axis: LitheSplitAxis
    let leadingBackground: Color
    let trailingBackground: Color
    let showsIdleDivider: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

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

    @ViewBuilder
    var body: some View {
        if axis == .horizontal {
            handleSurface.frame(maxHeight: .infinity)
        } else {
            handleSurface.frame(maxWidth: .infinity)
        }
    }

    private var handleSurface: some View {
        ZStack {
            trackBackground
            dividerLine
            SplitHandleInteractionView(
                axis: axis,
                onHoverChanged: { isHovering = $0 },
                onDragStateChanged: { isDragging = $0 },
                onDragStarted: onDragStarted,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            width: axis == .horizontal ? Self.thickness : nil,
            height: axis == .vertical ? Self.thickness : nil
        )
        .contentShape(Rectangle())
        .onDisappear {
            isHovering = false
            isDragging = false
        }
        .help(axis == .horizontal ? "Drag left or right to resize" : "Drag up or down to resize")
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
        let isHighlighted = isHovering || isDragging
        if showsIdleDivider {
            let color = isHighlighted ? LitheTheme.accent : LitheTheme.divider

            if axis == .horizontal {
                Rectangle()
                    .fill(color)
                    .frame(width: isDragging ? 3 : 1)
                    .frame(maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(color)
                    .frame(height: isDragging ? 3 : 1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

}

private struct SplitHandleInteractionView: NSViewRepresentable {
    let axis: LitheSplitAxis
    let onHoverChanged: (Bool) -> Void
    let onDragStateChanged: (Bool) -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> SplitHandleInteractionNSView {
        SplitHandleInteractionNSView(
            axis: axis,
            onHoverChanged: onHoverChanged,
            onDragStateChanged: onDragStateChanged,
            onDragStarted: onDragStarted,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }

    func updateNSView(_ nsView: SplitHandleInteractionNSView, context: Context) {
        nsView.update(
            axis: axis,
            onHoverChanged: onHoverChanged,
            onDragStateChanged: onDragStateChanged,
            onDragStarted: onDragStarted,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }

    static func dismantleNSView(_ nsView: SplitHandleInteractionNSView, coordinator: ()) {
        nsView.cancelInteraction()
    }
}

private final class SplitHandleInteractionNSView: NSView {
    private var axis: LitheSplitAxis
    private var onHoverChanged: (Bool) -> Void
    private var onDragStateChanged: (Bool) -> Void
    private var onDragStarted: () -> Void
    private var onDragChanged: (CGFloat) -> Void
    private var onDragEnded: (CGFloat) -> Void
    private var trackingArea: NSTrackingArea?
    private var dragStartInWindow: NSPoint?
    private var isDragging = false
    private var isInside = false

    init(
        axis: LitheSplitAxis,
        onHoverChanged: @escaping (Bool) -> Void,
        onDragStateChanged: @escaping (Bool) -> Void,
        onDragStarted: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping (CGFloat) -> Void
    ) {
        self.axis = axis
        self.onHoverChanged = onHoverChanged
        self.onDragStateChanged = onDragStateChanged
        self.onDragStarted = onDragStarted
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        onHoverChanged(true)
        resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        onHoverChanged(false)
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartInWindow = event.locationInWindow
        onDragStateChanged(true)
        resizeCursor.set()
        onDragStarted()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartInWindow else { return }
        onDragChanged(translation(from: dragStartInWindow, to: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartInWindow else { return }
        onDragEnded(translation(from: dragStartInWindow, to: event.locationInWindow))
        self.dragStartInWindow = nil
        isDragging = false
        onDragStateChanged(false)
        (isInside ? resizeCursor : NSCursor.arrow).set()
    }

    func update(
        axis: LitheSplitAxis,
        onHoverChanged: @escaping (Bool) -> Void,
        onDragStateChanged: @escaping (Bool) -> Void,
        onDragStarted: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping (CGFloat) -> Void
    ) {
        self.axis = axis
        self.onHoverChanged = onHoverChanged
        self.onDragStateChanged = onDragStateChanged
        self.onDragStarted = onDragStarted
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        window?.invalidateCursorRects(for: self)
    }

    func cancelInteraction() {
        dragStartInWindow = nil
        if isDragging {
            isDragging = false
            onDragStateChanged(false)
        }
        if isInside {
            isInside = false
            onHoverChanged(false)
        }
        NSCursor.arrow.set()
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private func translation(from start: NSPoint, to current: NSPoint) -> CGFloat {
        axis == .horizontal ? current.x - start.x : start.y - current.y
    }

    deinit {
        if isDragging || isInside {
            NSCursor.arrow.set()
        }
    }
}
