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
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var lastTranslation: CGFloat = 0

    init(
        axis: LitheSplitAxis,
        leadingBackground: Color = .clear,
        trailingBackground: Color = .clear,
        onDragStarted: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.axis = axis
        self.leadingBackground = leadingBackground
        self.trailingBackground = trailingBackground
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
                        lastTranslation = 0
                        onDragStarted()
                    }
                    let currentTranslation = axis == .horizontal ? value.translation.width : value.translation.height
                    // Only report changes larger than 1pt to reduce update frequency
                    if abs(currentTranslation - lastTranslation) >= 1 {
                        lastTranslation = currentTranslation
                        onDragChanged(currentTranslation)
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    lastTranslation = 0
                    onDragEnded()
                }
        )
        .onHover { isInside in
            guard isInside != isHovering else { return }
            isHovering = isInside
            if isInside {
                resizeCursor.set()
            } else {
                NSCursor.arrow.set()
            }
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
        let color = isDragging
            ? LitheTheme.accent.opacity(0.72)
            : LitheTheme.divider

        if axis == .horizontal {
            Rectangle()
                .fill(color)
                .frame(width: isDragging ? 3 : (isHovering ? 2 : 1))
                .frame(maxHeight: .infinity)
        } else {
            Rectangle()
                .fill(color)
                .frame(height: isDragging ? 3 : (isHovering ? 2 : 1))
                .frame(maxWidth: .infinity)
        }
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }
}
