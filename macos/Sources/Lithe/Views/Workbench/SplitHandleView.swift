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
    @State private var dragScheduler = LitheDragUpdateScheduler()
    @State private var dragSignpost: LitheSignpost.State?
    @State private var cursor = SplitHandleCursor()

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
            width: axis == .horizontal ? Self.thickness : nil,
            height: axis == .vertical ? Self.thickness : nil
        )
        .contentShape(Rectangle())
        .gesture(
            // The handle moves with the resized pane, so local coordinates create a
            // feedback loop where translation jumps as the coordinate origin moves.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        cursor.update(isResizing: true, cursor: resizeCursor)
                        dragSignpost = LitheSignpost.begin("split.drag")
                        onDragStarted()
                    }
                    let currentTranslation = axis == .horizontal ? value.translation.width : value.translation.height
                    // Pointer devices can deliver substantially more events than
                    // the display can present. The scheduler keeps only the
                    // newest translation for the next run-loop turn and applies
                    // the sub-point deadband, so no per-event @State is written.
                    dragScheduler.submit(currentTranslation) { translation in
                        // Resizing is direct manipulation. Do not let an
                        // inherited animation transaction turn each
                        // coalesced geometry update into a trailing animation.
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            onDragChanged(translation)
                        }
                    }
                }
                .onEnded { value in
                    let finalTranslation = axis == .horizontal
                        ? value.translation.width
                        : value.translation.height
                    dragScheduler.cancel()
                    isDragging = false
                    cursor.update(isResizing: isHovering, cursor: resizeCursor)
                    if let dragSignpost {
                        LitheSignpost.end("split.drag", dragSignpost)
                        self.dragSignpost = nil
                    }
                    onDragEnded(finalTranslation)
                }
        )
        .onHover { isInside in
            guard isInside != isHovering else { return }
            isHovering = isInside
            cursor.update(isResizing: isInside || isDragging, cursor: resizeCursor)
        }
        .onDisappear {
            dragScheduler.cancel()
            if let dragSignpost {
                LitheSignpost.end("split.drag", dragSignpost)
                self.dragSignpost = nil
            }
            cursor.update(isResizing: false, cursor: resizeCursor)
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

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }
}

private final class SplitHandleCursor {
    private var isResizing = false

    @MainActor
    func update(isResizing newValue: Bool, cursor: NSCursor) {
        guard newValue != isResizing else { return }
        isResizing = newValue
        if newValue {
            cursor.push()
        } else {
            NSCursor.pop()
        }
    }
}
