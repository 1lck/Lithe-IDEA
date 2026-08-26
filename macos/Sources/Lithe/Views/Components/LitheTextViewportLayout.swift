import AppKit

enum LitheTextViewportLayout {
    /// Keep the document wider than the viewport so resizing a surrounding
    /// pane moves the viewport instead of rewrapping every line in the file.
    @MainActor
    static func applyUnwrappedScrolling(
        to textView: NSTextView,
        in scrollView: NSScrollView
    ) {
        scrollView.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
    }
}
