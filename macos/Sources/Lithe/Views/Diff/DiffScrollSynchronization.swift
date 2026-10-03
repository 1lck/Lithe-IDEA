import AppKit
import SwiftUI

/// IDEA BaseSyncScrollable boundaries, projected onto our already laid-out source streams.
/// Matching spans retain their offset; an insertion clamps the shorter side until its end.
struct DiffScrollMapping {
    let boundaries: [(left: CGFloat, right: CGFloat)]

    init(layout: DiffSplitLayout) {
        boundaries = [(0, 0)] + layout.transitions.flatMap {
            [($0.leftRange.lowerBound, $0.rightRange.lowerBound),
             ($0.leftRange.upperBound, $0.rightRange.upperBound)]
        } + [(layout.leftHeight, layout.rightHeight)]
    }

    func transfer(_ y: CGFloat, from side: DiffSide) -> CGFloat {
        func source(_ i: Int) -> CGFloat { side == .left ? boundaries[i].left : boundaries[i].right }
        func target(_ i: Int) -> CGFloat { side == .left ? boundaries[i].right : boundaries[i].left }
        var low = 0, high = boundaries.count
        while low < high {
            let mid = (low + high) / 2
            if source(mid) < y { low = mid + 1 } else { high = mid }
        }
        let end = min(low, boundaries.count - 1), start = max(0, end - 1)
        if y == source(start) { return target(start) }
        if y == source(end) { return target(end) }
        if y > source(end) { return target(end) + y - source(end) }
        return min(target(start) + y - source(start), target(end))
    }
}

/// Native clip offsets never publish through SwiftUI or rebuild prepared code.
@MainActor
final class DiffScrollSynchronization: ObservableObject {
    private var identity: UUID?
    private var mapping: DiffScrollMapping?
    private var updating = false
    private weak var left: NSScrollView?
    private weak var right: NSScrollView?
    private var leftObserver: NSObjectProtocol?
    private var rightObserver: NSObjectProtocol?
    weak var transitionsView: DiffNativeTransitionsView?
    weak var leftStripe: DiffStripeScroller?
    weak var rightStripe: DiffStripeScroller?
    private var leftHeight: CGFloat = 1
    private var rightHeight: CGFloat = 1
    private(set) var transitions: [DiffSplitLayout.Transition] = []

    func configure(_ layout: DiffSplitLayout) {
        guard identity != layout.identity else { return }
        identity = layout.identity
        mapping = DiffScrollMapping(layout: layout)
        leftHeight = layout.leftHeight
        rightHeight = layout.rightHeight
        transitions = layout.transitions
        refresh()
    }

    func attach(_ view: NSScrollView, side: DiffSide) {
        guard scrollView(side) !== view else { return }
        detach(side: side)
        view.hasVerticalScroller = false
        view.hasHorizontalScroller = false
        view.contentView.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: view.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didScroll(side) }
            }
        if side == .left { left = view; leftObserver = token }
        else { right = view; rightObserver = token }
        refresh()
    }

    func detach(side: DiffSide) {
        let observer = side == .left ? leftObserver : rightObserver
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if side == .left { left = nil; leftObserver = nil }
        else { right = nil; rightObserver = nil }
    }

    deinit {
        if let leftObserver { NotificationCenter.default.removeObserver(leftObserver) }
        if let rightObserver { NotificationCenter.default.removeObserver(rightObserver) }
    }

    func scrollView(_ side: DiffSide) -> NSScrollView? { side == .left ? left : right }

    func scroll(_ side: DiffSide, to y: CGFloat) {
        guard let view = scrollView(side) else { return }
        let clip = view.contentView
        let maximum = max(0, clip.documentRect.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maximum)))
        view.reflectScrolledClipView(clip)
        didScroll(side)
    }

    private func didScroll(_ side: DiffSide) {
        guard !updating else { return }
        updating = true
        defer { updating = false; refresh() }
        guard let master = scrollView(side), let slave = scrollView(side == .left ? .right : .left),
              let mapping else { return }
        // SyncScrollSupport uses the line one third down the master viewport.
        let anchor = master.contentView.bounds.height / 3
        let target = mapping.transfer(master.contentView.bounds.minY + anchor, from: side) - anchor
        let clip = slave.contentView
        let maximum = max(0, clip.documentRect.height - clip.bounds.height)
        let y = min(max(0, target), maximum)
        if abs(clip.bounds.minY - y) > 0.1 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            slave.reflectScrolledClipView(clip)
        }
    }

    func refresh() {
        transitionsView?.leftOffset = left?.contentView.bounds.minY ?? 0
        transitionsView?.rightOffset = right?.contentView.bounds.minY ?? 0
        transitionsView?.needsDisplay = true
        for (side, stripe) in [(DiffSide.left, leftStripe), (.right, rightStripe)] {
            guard let stripe, let view = scrollView(side) else { continue }
            let clip = view.contentView
            stripe.sourceHeight = max(1, side == .left ? leftHeight : rightHeight)
            stripe.contentHeight = max(1, clip.documentRect.height)
            stripe.viewportHeight = clip.bounds.height
            stripe.knobProportion = min(1, clip.bounds.height / stripe.contentHeight)
            let maximum = max(0, stripe.contentHeight - clip.bounds.height)
            stripe.doubleValue = maximum > 0 ? clip.bounds.minY / maximum : 0
            stripe.needsDisplay = true
        }
    }
}

/// Probe must live inside its SwiftUI vertical ScrollView document.
struct DiffScrollAttachment: NSViewRepresentable {
    let synchronization: DiffScrollSynchronization
    let side: DiffSide
    func makeNSView(context: Context) -> Probe { Probe(synchronization: synchronization, side: side) }
    func updateNSView(_ view: Probe, context: Context) { view.attach() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        let synchronization: DiffScrollSynchronization
        let side: DiffSide
        private weak var attached: NSScrollView?
        init(synchronization: DiffScrollSynchronization, side: DiffSide) {
            self.synchronization = synchronization; self.side = side
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func attach() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            attached = scroll
            synchronization.attach(scroll, side: side)
        }
        func detach() {
            if synchronization.scrollView(side) === attached { synchronization.detach(side: side) }
            attached = nil
        }
    }
}

struct DiffErrorStripe: NSViewRepresentable {
    let synchronization: DiffScrollSynchronization
    let side: DiffSide
    func makeNSView(context: Context) -> DiffStripeScroller {
        let view = DiffStripeScroller(frame: NSRect(x: 0, y: 0, width: LitheScrollBarStyle.editorThickness, height: 100))
        view.side = side; view.synchronization = synchronization
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.scrollBar)
        view.setAccessibilityOrientation(.vertical)
        view.setAccessibilityLabel(side == .left ? "Original diff change markers" : "Modified diff change markers")
        return view
    }
    func updateNSView(_ view: DiffStripeScroller, context: Context) {
        if side == .left { synchronization.leftStripe = view } else { synchronization.rightStripe = view }
        view.transitions = synchronization.transitions
        synchronization.refresh()
    }
}

/// Reuses compact scroller geometry/paint; this visible view owns pointer tracking.
final class DiffStripeScroller: NSView {
    private let scroller = LitheScrollViewChrome.CompactScroller(frame:
        NSRect(x: 0, y: 0, width: LitheScrollBarStyle.editorThickness, height: 100))
    override var isFlipped: Bool { true }
    var knobProportion: CGFloat {
        get { scroller.knobProportion }
        set { scroller.knobProportion = newValue }
    }
    var doubleValue: Double {
        get { scroller.doubleValue }
        set { scroller.doubleValue = newValue }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        // AppKit's layer-backed NSScroller paints its own track instead of draw(_:).
        // Use its geometry/paint, but never forward mouseDown into an invisible
        // child: that child cannot own subsequent events delivered to this view.
        scroller.role = .editor
        scroller.onPaintChange = { [weak self] in self?.needsDisplay = true }
        scroller.alphaValue = 0
        scroller.scrollerStyle = .legacy
        addSubview(scroller)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); scroller.frame = bounds; scroller.mirrored = side == .left }
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { scroller.setHovered(true); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { scroller.setHovered(false); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    weak var synchronization: DiffScrollSynchronization?
    var side: DiffSide = .left
    var transitions: [DiffSplitLayout.Transition] = []
    var sourceHeight: CGFloat = 1
    var contentHeight: CGFloat = 1
    var viewportHeight: CGFloat = 0
    private var dragStart: (windowY: CGFloat, value: Double, travel: CGFloat)?
    var knobRect: NSRect { side == .right && knobProportion < 1 ? scroller.rect(for: .knob) : .zero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func markerRect(_ transition: DiffSplitLayout.Transition) -> NSRect {
        let range = side == .left ? transition.leftRange : transition.rightRange
        // EditorMarkupModelImpl.offsetsToYPositions never stretches a short
        // document's markers across the viewport; only long files are compressed.
        let scale = min(1, bounds.height / max(1, sourceHeight))
        // DiffDrawUtil uses a wide error stripe, not the thin VCS stripe. The
        // highlighter ends on the final changed line, not the following line.
        let start = floor(range.lowerBound * scale)
        let end = floor(max(range.lowerBound, range.upperBound - DiffLayoutMetrics.rowHeight) * scale)
        let height = max(LitheScrollBarStyle.minimumMarkHeight, end - start)
        return NSRect(x: side == .left ? 0 : LitheScrollBarStyle.editorThickness - LitheScrollBarStyle.thickness,
                      y: min(max(0, bounds.height - height), start),
                      width: LitheScrollBarStyle.thickness, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor(LitheTheme.Diff.background).setFill()
        dirtyRect.fill()
        for transition in transitions {
            let color = transition.kind == .addition ? LitheTheme.Diff.insertedStripe
                : transition.kind == .removal ? LitheTheme.Diff.deletedStripe : LitheTheme.Diff.modifiedStripe
            NSColor(color).setFill()
            markerRect(transition).fill()
        }
        if !knobRect.isEmpty { scroller.drawKnob() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !knobRect.isEmpty, knobRect.contains(point) {
            dragStart = (event.locationInWindow.y, doubleValue,
                max(0, scroller.rect(for: .knobSlot).height - knobRect.height))
            scroller.setHovered(true, animated: false)
        } else if let marker = transitions.min(by: {
            abs(markerRect($0).midY - point.y) < abs(markerRect($1).midY - point.y)
        }), markerRect(marker).insetBy(dx: -3, dy: -3).contains(point) {
            let range = side == .left ? marker.leftRange : marker.rightRange
            synchronization?.scroll(side, to: range.lowerBound - viewportHeight / 3)
        } else if side == .right, let scroll = synchronization?.scrollView(side) {
            let direction: CGFloat = point.y < knobRect.minY ? -1 : 1
            synchronization?.scroll(side, to: scroll.contentView.bounds.minY + direction * viewportHeight * 0.9)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, dragStart.travel > 0 else { return }
        let value = min(max(dragStart.value + (dragStart.windowY - event.locationInWindow.y) / dragStart.travel, 0), 1)
        synchronization?.scroll(side, to: value * max(0, contentHeight - viewportHeight))
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        dragStart = nil
        scroller.setHovered(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func scrollWheel(with event: NSEvent) { synchronization?.scrollView(side)?.scrollWheel(with: event) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dragStart = nil }
    }

    override func accessibilityValue() -> Any? { doubleValue }
    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? NSNumber else { return }
        synchronization?.scroll(side, to: CGFloat(value.doubleValue) * max(0, contentHeight - viewportHeight))
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard let scroll = synchronization?.scrollView(side) else { return false }
        synchronization?.scroll(side, to: scroll.contentView.bounds.minY + DiffLayoutMetrics.rowHeight)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard let scroll = synchronization?.scrollView(side) else { return false }
        synchronization?.scroll(side, to: scroll.contentView.bounds.minY - DiffLayoutMetrics.rowHeight)
        return true
    }

}
