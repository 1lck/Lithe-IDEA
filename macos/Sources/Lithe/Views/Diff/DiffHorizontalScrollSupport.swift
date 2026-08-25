import AppKit
import SwiftUI

/// One IDEA-style horizontal scroller controls both fixed-width diff panes.
/// The panes keep their on-screen geometry while their code content shares the
/// same pixel offset.
struct DiffHorizontalScroller: View {
    @Binding var offset: CGFloat
    let viewportWidth: CGFloat
    let contentWidth: CGFloat

    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isHovering = false

    private var maximumOffset: CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(0, geometry.size.width - 12)
            let visibleFraction = contentWidth > 0
                ? min(1, viewportWidth / contentWidth)
                : 1
            let thumbWidth = min(trackWidth, max(46, trackWidth * visibleFraction))
            let travel = max(0, trackWidth - thumbWidth)
            let thumbOffset = maximumOffset > 0
                ? min(max(offset / maximumOffset, 0), 1) * travel
                : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LitheTheme.divider.opacity(isHovering || isDragging ? 0.55 : 0.28))
                    .frame(height: 3)

                Capsule()
                    .fill(
                        isDragging
                            ? LitheTheme.accent.opacity(0.78)
                            : LitheTheme.secondaryText.opacity(isHovering ? 0.72 : 0.48)
                    )
                    .frame(width: thumbWidth, height: isDragging ? 6 : 5)
                    .offset(x: thumbOffset)
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartOffset = offset
                                }
                                guard travel > 0 else { return }
                                offset = constrained(
                                    dragStartOffset + (value.translation.width / travel) * maximumOffset
                                )
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
            }
            .frame(width: trackWidth, height: geometry.size.height)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
        .frame(height: 10)
        .background(LitheTheme.window.opacity(isHovering || isDragging ? 0.82 : 0.48))
        .opacity(maximumOffset > 0.5 ? 1 : 0)
        .allowsHitTesting(maximumOffset > 0.5)
        .accessibilityLabel("Synchronized diff horizontal scroll")
        .onChange(of: maximumOffset) { newMaximum in
            offset = min(max(offset, 0), newMaximum)
        }
    }

    private func constrained(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), maximumOffset)
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
                return event
            }
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }
}
