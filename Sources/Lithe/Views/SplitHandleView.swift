import AppKit
import SwiftUI

enum LitheSplitAxis {
    case horizontal
    case vertical
}

struct SplitHandleView: View {
    static let thickness: CGFloat = 6

    let axis: LitheSplitAxis
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
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
                        onDragStarted()
                    }
                    onDragChanged(axis == .horizontal ? value.translation.width : value.translation.height)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnded()
                }
        )
        .onHover { isInside in
            guard isInside != isHovering else { return }
            isHovering = isInside
            if isInside {
                resizeCursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
            }
        }
        .help(axis == .horizontal ? "Drag left or right to resize" : "Drag up or down to resize")
        .accessibilityLabel(axis == .horizontal ? "Horizontal pane resize handle" : "Vertical pane resize handle")
    }

    @ViewBuilder
    private var dividerLine: some View {
        let color = isDragging
            ? LitheTheme.accent.opacity(0.72)
            : LitheTheme.divider.opacity(isHovering ? 1.8 : 1)

        if axis == .horizontal {
            Rectangle()
                .fill(color)
                .frame(width: isDragging ? 2 : 1)
                .frame(maxHeight: .infinity)
        } else {
            Rectangle()
                .fill(color)
                .frame(height: isDragging ? 2 : 1)
                .frame(maxWidth: .infinity)
        }
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }
}
