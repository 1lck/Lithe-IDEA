import AppKit
import SwiftUI

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

            // Persistent scrollers require legacy style because AppKit owns
            // overlay fade behavior. Non-persistent scrollers remain overlay.
            let scrollerStyle: NSScroller.Style = alwaysShowVertical ? .legacy : .overlay
            if scrollView.scrollerStyle != scrollerStyle {
                scrollView.scrollerStyle = scrollerStyle
            }
            if scrollView.autohidesScrollers != !alwaysShowVertical {
                scrollView.autohidesScrollers = !alwaysShowVertical
            }
            if scrollView.verticalScroller?.knobStyle != .dark {
                scrollView.verticalScroller?.knobStyle = .dark
            }
            if scrollView.horizontalScroller?.knobStyle != .dark {
                scrollView.horizontalScroller?.knobStyle = .dark
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
                      self.isEvent(event, inside: scrollView),
                      self.canScrollVertically(scrollView) else { return event }
                scrollView.scrollWheel(with: event)
                return nil
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

        private func canScrollVertically(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return false }
            return documentView.bounds.height > scrollView.contentView.bounds.height + 0.5
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
            let sidebar = LitheTheme.nsColor(.sidebar, isDark: isDark)
            let secondaryText = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            let thumbColor = sidebar.blended(withFraction: 0.28, of: secondaryText)
                ?? secondaryText
            thumbColor.withAlphaComponent(0.95).setFill()
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
