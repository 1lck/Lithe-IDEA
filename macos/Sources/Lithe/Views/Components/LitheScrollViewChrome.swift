import AppKit
import SwiftUI

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

/// Keeps SwiftUI scroll views visually close to IntelliJ's overlay scrollers.
/// SwiftUI otherwise inherits the user's macOS "Always show scroll bars"
/// setting, which can turn a compact tool window into a set of bright, thick
/// tracks. The probe configures only the enclosing NSScrollView and occupies
/// no visible content of its own.
struct LitheScrollViewChrome: NSViewRepresentable {
    var hideHorizontal = false
    var alwaysShowVertical = false
    var usesCompactScrollers = false

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
                    scroller?.wantsLayer = true
                    scroller?.layer?.backgroundColor = NSColor.clear.cgColor
                }
            }
            let controlSize: NSControl.ControlSize = usesCompactScrollers ? .mini : .regular
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

    /// Draws only a compact thumb in either persistent legacy or fading overlay
    /// mode. Omitting the knob slot avoids adding a visible track background.
    final class CompactScroller: NSScroller {
        override class var isCompatibleWithOverlayScrollers: Bool { true }
        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            drawKnob()
        }

        override func drawKnob() {
            var knobRect = rect(for: .knob)
            guard !knobRect.isEmpty else { return }

            if bounds.height >= bounds.width {
                let horizontalInset = max(2, (knobRect.width - 5) / 2)
                knobRect = knobRect.insetBy(dx: horizontalInset, dy: 1)
            } else {
                let verticalInset = max(2, (knobRect.height - 5) / 2)
                knobRect = knobRect.insetBy(dx: 1, dy: verticalInset)
            }
            guard knobRect.width > 0, knobRect.height > 0 else { return }

            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let secondaryText = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            let thumbColor = isDark && LitheTheme.activeTheme == .lithe
                ? NSColor(srgbRed: 67.0 / 255.0, green: 67.0 / 255.0, blue: 67.0 / 255.0, alpha: 1)
                : secondaryText.withAlphaComponent(isDark ? 0.62 : 0.36)
            thumbColor.setFill()
            NSBezierPath(
                roundedRect: knobRect,
                xRadius: min(2.5, knobRect.width / 2),
                yRadius: min(2.5, knobRect.height / 2)
            ).fill()
        }
    }
}

extension View {
    func litheScrollViewChrome(
        hideHorizontal: Bool = false,
        alwaysShowVertical: Bool = false,
        usesCompactScrollers: Bool = false
    ) -> some View {
        background(LitheScrollViewChrome(
            hideHorizontal: hideHorizontal,
            alwaysShowVertical: alwaysShowVertical,
            usesCompactScrollers: usesCompactScrollers
        ))
    }
}
