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

    func makeNSView(context: Context) -> ScrollViewProbe {
        ScrollViewProbe(hideHorizontal: hideHorizontal, alwaysShowVertical: alwaysShowVertical)
    }

    func updateNSView(_ nsView: ScrollViewProbe, context: Context) {
        nsView.hideHorizontal = hideHorizontal
        nsView.alwaysShowVertical = alwaysShowVertical
        nsView.configureEnclosingScrollView()
    }

    final class ScrollViewProbe: NSView {
        var hideHorizontal: Bool
        var alwaysShowVertical: Bool

        init(hideHorizontal: Bool, alwaysShowVertical: Bool) {
            self.hideHorizontal = hideHorizontal
            self.alwaysShowVertical = alwaysShowVertical
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureEnclosingScrollView()
        }

        override func layout() {
            super.layout()
            configureEnclosingScrollView()
        }

        func configureEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else { return }

            scrollView.scrollerStyle = alwaysShowVertical ? .legacy : .overlay
            scrollView.autohidesScrollers = !alwaysShowVertical
            scrollView.hasVerticalScroller = true
            scrollView.verticalScroller?.knobStyle = .dark
            scrollView.horizontalScroller?.knobStyle = .dark

            if hideHorizontal {
                scrollView.hasHorizontalScroller = false
                scrollView.horizontalScrollElasticity = .none
            }
        }
    }
}

extension View {
    func litheScrollViewChrome(
        hideHorizontal: Bool = false,
        alwaysShowVertical: Bool = false
    ) -> some View {
        background(LitheScrollViewChrome(
            hideHorizontal: hideHorizontal,
            alwaysShowVertical: alwaysShowVertical
        ))
    }
}
