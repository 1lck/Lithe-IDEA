import AppKit
import SwiftUI
import QuartzCore

enum LitheScrollWheelDestination: Equatable {
    case nested
    case outer
    case unchanged
}

enum LitheScrollWheelRouting {
    static func destination(
        hitsNestedScrollView: Bool,
        nestedCanScrollInDirection: Bool,
        outerCanScrollInDirection: Bool
    ) -> LitheScrollWheelDestination {
        if hitsNestedScrollView, nestedCanScrollInDirection {
            return .nested
        }
        return outerCanScrollInDirection ? .outer : .unchanged
    }

    static func destination(
        hitView: NSView?,
        within outerScrollView: NSScrollView,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> LitheScrollWheelDestination {
        let nearestScrollView = nearestScrollView(from: hitView, within: outerScrollView)
        let hitsNestedScrollView = nearestScrollView != nil && nearestScrollView !== outerScrollView
        return destination(
            hitsNestedScrollView: hitsNestedScrollView,
            nestedCanScrollInDirection: hitsNestedScrollView
                && canScroll(nearestScrollView, deltaX: deltaX, deltaY: deltaY),
            outerCanScrollInDirection: canScroll(
                outerScrollView,
                deltaX: deltaX,
                deltaY: deltaY
            )
        )
    }

    static func nearestScrollView(
        from hitView: NSView?,
        within outerScrollView: NSScrollView
    ) -> NSScrollView? {
        var candidate = hitView
        while let current = candidate {
            if let scrollView = current as? NSScrollView,
               scrollView === outerScrollView || scrollView.isDescendant(of: outerScrollView) {
                return scrollView
            }
            candidate = current.superview
        }
        return nil
    }

    static func canScroll(
        _ scrollView: NSScrollView?,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Bool {
        guard let scrollView,
              abs(deltaY) > abs(deltaX),
              deltaY != 0 else { return false }
        let clipView = scrollView.contentView
        let documentRect = clipView.documentRect
        let minimumY = documentRect.minY
        let maximumY = max(minimumY, documentRect.maxY - clipView.bounds.height)
        guard maximumY - minimumY > 0.5 else { return false }
        let currentY = clipView.bounds.minY
        return deltaY > 0
            ? currentY > minimumY + 0.5
            : currentY < maximumY - 0.5
    }
}

/// IDEA ScrollBarPainter / MacScrollBarUI; editors override the same painter.
/// The rail belongs to its host surface, never to a hardcoded sidebar color.
enum LitheScrollBarStyle {
    enum Role { case product, editor }
    static let thickness: CGFloat = 14
    static let editorThickness: CGFloat = thickness + 2 + 2
    static let minimumMarkHeight: CGFloat = 2

    static func thumbRect(in bounds: NSRect, knob: NSRect, role: Role,
                          hover: CGFloat, mirrored: Bool = false, opaque: Bool = false, dark: Bool = true) -> NSRect {
        let vertical = bounds.height >= bounds.width
        let cross = vertical ? bounds.width : bounds.height
        // EditorMarkupModelImpl centers a 7→10pt overlay thumb in its 14pt lane;
        // ButtonlessScrollBarUI expands by 2 before ScrollBarPainter's 1pt inset.
        // In light UI fill == border, so IDEA omits the border and insets 2pt.
        let margin: CGFloat = dark ? 1 : 2
        let width: CGFloat = role == .editor ? 11 + 3 * hover - 2 * margin
            : opaque ? 9 - 2 * margin : 11 + 3 * hover - 2 * margin
        let center = role == .editor ? (cross >= editorThickness ? 4 + thickness / 2 : cross / 2)
            : cross - (opaque ? 11 : 11 + 3 * hover) / 2
        let alongInset = margin + (role == .product && opaque ? 1 : 0)
        let start = mirrored ? cross - center - width / 2 : center - width / 2
        return vertical ? NSRect(x: start, y: knob.minY + alongInset, width: width, height: max(0, knob.height - 2 * alongInset))
            : NSRect(x: knob.minX + alongInset, y: start, width: max(0, knob.width - 2 * alongInset), height: width)
    }

    static func paint(bounds: NSRect, knob: NSRect, role: Role, dark: Bool,
                      hover: CGFloat, mirrored: Bool = false, opaque: Bool = false) {
        func rgba(_ rgb: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        }
        // Mac trackColor is transparent; the transparent hover track uses 8080801A.
        if role == .product && !opaque {
            rgba(0x808080, hover * 26 / 255).setFill()
            bounds.fill()
        }
        guard !knob.isEmpty else { return }
        let rect = thumbRect(in: bounds, knob: knob, role: role, hover: hover, mirrored: mirrored, opaque: opaque, dark: dark)
        guard rect.width > 0, rect.height > 0 else { return }
        let fill = dark ? rgba(role == .editor ? 0xFFFFFF : 0x808080,
                              role == .editor ? (38 + 39 * hover) / 255 : (89 + 51 * hover) / 255)
            : rgba(0, (51 + 77 * hover) / 255)
        let border = dark ? rgba(0x262626, (89 + 51 * hover) / 255) : fill
        let radius = min(rect.width, rect.height) / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        if dark {
            // RectanglePainter fills inside its border; translucent borders
            // must not be composited over an already filled outline.
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: max(0, radius - 1), yRadius: max(0, radius - 1)).fill()
            border.setStroke()
            let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
            stroke.lineWidth = 1; stroke.stroke()
        } else { path.fill() }
    }
}

/// Paint-only adapter: callers keep their existing scroll/drag actions.
struct LitheScrollBarPaint: NSViewRepresentable {
    let knob: NSRect
    let hover: CGFloat
    let role: LitheScrollBarStyle.Role
    func makeNSView(context: Context) -> PaintView { PaintView() }
    func updateNSView(_ view: PaintView, context: Context) {
        view.knob = knob; view.hover = hover; view.role = role; view.needsDisplay = true
    }
    final class PaintView: NSView {
        var knob: NSRect = .zero
        var hover: CGFloat = 0
        var role: LitheScrollBarStyle.Role = .product
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            LitheScrollBarStyle.paint(bounds: bounds, knob: knob, role: role,
                dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, hover: hover)
        }
    }
}

/// Keeps SwiftUI scroll views visually close to IntelliJ's overlay scrollers.
/// SwiftUI otherwise inherits the user's macOS "Always show scroll bars"
/// setting, which can turn a compact tool window into a set of bright, thick
/// tracks. The probe configures only the enclosing NSScrollView and occupies
/// no visible content of its own.
struct LitheScrollViewChrome: NSViewRepresentable {
    var hideHorizontal = false
    var alwaysShowVertical = false
    var usesCompactScrollers = true

    func makeNSView(context: Context) -> ScrollViewProbe {
        ScrollViewProbe(
            hideHorizontal: hideHorizontal,
            alwaysShowVertical: alwaysShowVertical,
            usesCompactScrollers: usesCompactScrollers
        )
    }

    func updateNSView(_ nsView: ScrollViewProbe, context: Context) {
        nsView.hideHorizontal = hideHorizontal
        nsView.alwaysShowVertical = alwaysShowVertical
        nsView.usesCompactScrollers = usesCompactScrollers
        nsView.configureEnclosingScrollView()
        nsView.needsDisplay = true
    }

    final class ScrollViewProbe: NSView {
        var hideHorizontal: Bool
        var alwaysShowVertical: Bool
        var usesCompactScrollers: Bool
        private weak var configuredScrollView: NSScrollView?
        private var scrollWheelMonitor: Any?

        init(
            hideHorizontal: Bool,
            alwaysShowVertical: Bool,
            usesCompactScrollers: Bool
        ) {
            self.hideHorizontal = hideHorizontal
            self.alwaysShowVertical = alwaysShowVertical
            self.usesCompactScrollers = usesCompactScrollers
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeScrollWheelMonitor()
            }
            configureEnclosingScrollView()
        }

        override func layout() {
            super.layout()
            configureEnclosingScrollView()
        }

        /// Assigning any of these properties makes AppKit re-tile the scroll view,
        /// which calls back into `layout()`. Writing only genuine changes keeps
        /// that from becoming a layout feedback loop on every redraw.
        func configureEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else { return }

            if !scrollView.hasVerticalScroller {
                scrollView.hasVerticalScroller = true
            }
            // Persistent scrollers require legacy style because AppKit owns
            // overlay fade behavior. Non-persistent scrollers remain overlay.
            let scrollerStyle: NSScroller.Style = alwaysShowVertical ? .legacy : .overlay
            if scrollView.scrollerStyle != scrollerStyle {
                scrollView.scrollerStyle = scrollerStyle
            }
            if scrollView.autohidesScrollers != !alwaysShowVertical {
                scrollView.autohidesScrollers = !alwaysShowVertical
            }
            let isDark = scrollView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let knobStyle: NSScroller.KnobStyle = isDark ? .light : .dark
            if scrollView.verticalScroller?.knobStyle != knobStyle {
                scrollView.verticalScroller?.knobStyle = knobStyle
            }
            if scrollView.horizontalScroller?.knobStyle != knobStyle {
                scrollView.horizontalScroller?.knobStyle = knobStyle
            }
            if usesCompactScrollers {
                if !(scrollView.verticalScroller is CompactScroller) {
                    scrollView.verticalScroller = CompactScroller()
                }
                if !hideHorizontal,
                   !(scrollView.horizontalScroller is CompactScroller) {
                    scrollView.horizontalScroller = CompactScroller()
                }
                if scrollView.drawsBackground {
                    scrollView.drawsBackground = false
                }
                if scrollView.contentView.drawsBackground {
                    scrollView.contentView.drawsBackground = false
                }
                for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller] {
                    scroller?.wantsLayer = false
                    scroller?.layer?.backgroundColor = NSColor.clear.cgColor
                }
            }
            let controlSize: NSControl.ControlSize = .regular
            if scrollView.verticalScroller?.controlSize != controlSize {
                scrollView.verticalScroller?.controlSize = controlSize
            }
            if scrollView.horizontalScroller?.controlSize != controlSize {
                scrollView.horizontalScroller?.controlSize = controlSize
            }

            if hideHorizontal {
                if scrollView.hasHorizontalScroller {
                    scrollView.hasHorizontalScroller = false
                }
                if scrollView.horizontalScrollElasticity != .none {
                    scrollView.horizontalScrollElasticity = .none
                }
            }
            configureScrollWheelMonitor(for: scrollView)
        }

        deinit {
            removeScrollWheelMonitor()
        }

        private func configureScrollWheelMonitor(for scrollView: NSScrollView) {
            guard alwaysShowVertical else {
                removeScrollWheelMonitor()
                configuredScrollView = nil
                return
            }
            guard configuredScrollView !== scrollView || scrollWheelMonitor == nil else { return }
            removeScrollWheelMonitor()
            configuredScrollView = scrollView
            scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scrollView] event in
                guard let self,
                      let scrollView,
                      self.isEvent(event, inside: scrollView) else { return event }
                let destination = LitheScrollWheelRouting.destination(
                    hitView: self.hitView(for: event),
                    within: scrollView,
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY
                )
                switch destination {
                case .nested, .unchanged:
                    return event
                case .outer:
                    scrollView.scrollWheel(with: event)
                    return nil
                }
            }
        }

        private func removeScrollWheelMonitor() {
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor)
                self.scrollWheelMonitor = nil
            }
        }

        private func isEvent(_ event: NSEvent, inside scrollView: NSScrollView) -> Bool {
            guard event.window === scrollView.window else { return false }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            return scrollView.bounds.contains(point)
        }

        private func hitView(for event: NSEvent) -> NSView? {
            guard let contentView = event.window?.contentView else { return nil }
            let point = contentView.convert(event.locationInWindow, from: nil)
            return contentView.hitTest(point)
        }
    }

    /// Shared Mac thumb/hover-track paint; AppKit retains native tracking and
    /// overlay fading. The host surface remains visible through the idle rail.
    final class CompactScroller: NSScroller {
        override class var isCompatibleWithOverlayScrollers: Bool { true }
        override var isOpaque: Bool { false }
        override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
            LitheScrollBarStyle.thickness
        }

        var role: LitheScrollBarStyle.Role = .product
        var mirrored = false
        var onPaintChange: (() -> Void)?
        @objc dynamic var hoverAmount: CGFloat = 0 { didSet { needsDisplay = true; onPaintChange?() } }
        private var hoverTracking: NSTrackingArea?

        override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
            key == "hoverAmount" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); hoverTracking = area
        }
        func setHovered(_ hovered: Bool, animated: Bool = true) {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.125
                    animator().hoverAmount = hovered ? 1 : 0
                }
            } else { hoverAmount = hovered ? 1 : 0 }
        }
        override func mouseEntered(with event: NSEvent) { setHovered(true) }
        override func mouseExited(with event: NSEvent) { setHovered(false) }
        override func mouseDown(with event: NSEvent) {
            setHovered(true, animated: false)
            super.mouseDown(with: event)
            if let window { setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
        }
        override func draw(_ dirtyRect: NSRect) { drawKnob() }
        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
        override func drawKnob() {
            LitheScrollBarStyle.paint(bounds: bounds,
                knob: knobProportion < 1 ? rect(for: .knob) : .zero, role: role,
                dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                hover: hoverAmount, mirrored: mirrored, opaque: scrollerStyle == .legacy && role == .product)
        }

    }
}

extension View {
    func litheScrollViewChrome(
        hideHorizontal: Bool = false,
        alwaysShowVertical: Bool = false,
        usesCompactScrollers: Bool = true
    ) -> some View {
        background(LitheScrollViewChrome(
            hideHorizontal: hideHorizontal,
            alwaysShowVertical: alwaysShowVertical,
            usesCompactScrollers: usesCompactScrollers
        ))
    }
}
