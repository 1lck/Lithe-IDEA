import AppKit
import os
import SwiftUI

enum LitheSplitAxis {
    case horizontal
    case vertical
}

private struct SplitHandleHitTestRegistryKey: EnvironmentKey {
    static let defaultValue: SplitHandleHitTestRegistry? = nil
}

extension EnvironmentValues {
    var splitHandleHitTestRegistry: SplitHandleHitTestRegistry? {
        get { self[SplitHandleHitTestRegistryKey.self] }
        set { self[SplitHandleHitTestRegistryKey.self] = newValue }
    }
}

/// Only layout handles in one workbench opt in. Retained tools keep their own
/// native traversal; querying an ancestor's hitTest here would reenter SwiftUI.
@MainActor
final class SplitHandleHitTestRegistry {
    private let handles = NSHashTable<SplitHandleInteractionView>.weakObjects()

    fileprivate func insert(_ handle: SplitHandleInteractionView) { handles.add(handle) }
    fileprivate func remove(_ handle: SplitHandleInteractionView) { handles.remove(handle) }

    func handle(at point: NSPoint, in surface: NSView) -> SplitHandleInteractionView? {
        guard let window = surface.window else { return nil }
        var frontmost: SplitHandleInteractionView?
        for handle in handles.allObjects {
            guard handle.window === window, !handle.isHiddenOrHasHiddenAncestor,
                  !handle.isDescendant(of: surface),
                  handle.bounds.intersection(handle.visibleRect).contains(handle.convert(point, from: surface)) else {
                continue
            }
            var ancestor: NSView? = handle
            while let view = ancestor, view.alphaValue > 0 { ancestor = view.superview }
            guard ancestor == nil else { continue }
            if let previous = frontmost, !isAbove(handle, previous) { continue }
            frontmost = handle
        }
        return frontmost
    }

    private func isAbove(_ view: NSView, _ other: NSView) -> Bool {
        guard let common = view.ancestorShared(with: other) else { return false }
        if common === view { return false }
        if common === other { return true }
        var branch = view
        var otherBranch = other
        while let parent = branch.superview, parent !== common { branch = parent }
        while let parent = otherBranch.superview, parent !== common { otherBranch = parent }
        guard let index = common.subviews.firstIndex(of: branch),
              let otherIndex = common.subviews.firstIndex(of: otherBranch) else { return false }
        return index > otherIndex
    }
}

struct SplitHandleView: View {
    // Keep the hit target wider than the visible divider so resizing does not
    // depend on landing on a single pixel row or column.
    static let thickness: CGFloat = 5
    static let hitThickness: CGFloat = 10
    static let visibleTrackThickness: CGFloat = 2

    let axis: LitheSplitAxis
    let trackBackground: Color
    let dividerColor: Color
    let showsIdleDivider: Bool
    let isHitTestEnabled: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var dragScheduler = LitheDragUpdateScheduler()
    @State private var dragSignpost: LitheSignpost.State?

    init(
        axis: LitheSplitAxis,
        trackBackground: Color = .clear,
        dividerColor: Color = LitheTheme.divider,
        showsIdleDivider: Bool = true,
        isHitTestEnabled: Bool = true,
        onDragStarted: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping (CGFloat) -> Void
    ) {
        self.axis = axis
        self.trackBackground = trackBackground
        self.dividerColor = dividerColor
        self.showsIdleDivider = showsIdleDivider
        self.isHitTestEnabled = isHitTestEnabled
        self.onDragStarted = onDragStarted
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        ZStack {
            trackBackground
                .frame(
                    width: axis == .horizontal ? Self.visibleTrackThickness : nil,
                    height: axis == .vertical ? Self.visibleTrackThickness : nil
                )
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
                isHitTestEnabled: isHitTestEnabled,
                onDragStarted: {
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
    private var dividerLine: some View {
        if showsIdleDivider {
            if axis == .horizontal {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

}

private struct SplitHandleInteraction: NSViewRepresentable {
    let axis: LitheSplitAxis
    let isHitTestEnabled: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    @Environment(\.splitHandleHitTestRegistry) private var hitTestRegistry
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> SplitHandleInteractionView {
        let view = SplitHandleInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SplitHandleInteractionView, context: Context) {
        view.axis = axis
        view.onDragStarted = onDragStarted
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.hitTestRegistry = isEnabled && isHitTestEnabled ? hitTestRegistry : nil
    }

    static func dismantleNSView(_ view: SplitHandleInteractionView, coordinator: ()) {
        view.hitTestRegistry = nil
    }
}

/// The native hit target owns both cursor tracking and drag delivery. A cursor
/// background that returns nil from hitTest leaves NSHostingView in charge of
/// the pointer and lets it overwrite the resize cursor after native editor exit.
final class SplitHandleInteractionView: NSView {
    weak var hitTestRegistry: SplitHandleHitTestRegistry? {
        didSet {
            guard hitTestRegistry !== oldValue else { return }
            oldValue?.remove(self)
            if window != nil { hitTestRegistry?.insert(self) }
        }
    }
    var axis: LitheSplitAxis = .horizontal {
        didSet {
            guard axis != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
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
        if window == nil {
            dragStartPoint = nil
            hitTestRegistry?.remove(self)
        } else {
            hitTestRegistry?.insert(self)
        }
    }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseMoved(with event: NSEvent) { resizeCursor.set() }

    override func mouseEntered(with event: NSEvent) {
        resizeCursor.set()
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
