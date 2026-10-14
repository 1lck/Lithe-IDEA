import AppKit

enum LitheTextViewportLayout {
    /// Delayed tracking events must not overwrite the cursor of a foreground control or neighbouring divider.
    @MainActor
    static func isPointerHitTarget(_ view: NSView?, at windowPoint: NSPoint) -> Bool {
        // hitTest takes superview coordinates, including when the content view is a flipped NSHostingView.
        guard let view, let contentView = view.window?.contentView,
              let hit = contentView.hitTest(contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint) else { return false }
        return hit === view || hit.isDescendant(of: view)
    }

    /// Above this logical line count, soft wrap stays unavailable: rewrapping
    /// the whole buffer on every pane resize would stall the main thread, so
    /// oversized documents keep the unwrapped geometry regardless of the
    /// user's soft-wrap preference.
    static let softWrapMaximumLineCount = 50_000

    static func isSoftWrapSupported(lineCount: Int) -> Bool {
        lineCount <= softWrapMaximumLineCount
    }

    /// 按编辑器 `TextLineIndex` 的同一套行终止符语义统计文本行数，
    /// 用于在缓冲区尚未替换时判定"本次即将显示的内容"。
    static func lineCount(of text: String) -> Int {
        TextLineIndex(source: text as NSString).lineCount
    }

    @MainActor
    static func consoleLineHeight(in textView: NSTextView) -> CGFloat {
        (textView.layoutManager?.defaultLineHeight(for: textView.font ?? LitheTheme.editorFont(size: 13)) ?? 0)
            * LitheTheme.editorLineHeightMultiple
    }

    /// One TextKit rectangle for both the console text and its gutter, including the empty final line.
    @MainActor
    static func consoleCaretLineRect(in textView: NSTextView) -> NSRect {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return .zero }
        layout.ensureLayout(for: container)
        var rect = NSRect(x: 0, y: textView.textContainerOrigin.y, width: textView.bounds.width,
                          height: consoleLineHeight(in: textView))
        let length = textView.string.utf16.count
        let finalLineIsEmpty = length > 0 && (textView.string as NSString).lineRange(for: NSRange(location: length, length: 0)).location == length
        if length > 0, textView.selectedRange().location < length || !finalLineIsEmpty {
            let glyph = layout.glyphIndexForCharacter(at: min(textView.selectedRange().location, length - 1))
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y += fragment.minY
            rect.size.height = fragment.height
        } else if length > 0 {
            rect.origin.y += layout.extraLineFragmentRect.minY
        }
        return rect
    }

    /// 一次更新中软换行的最终判定。`incomingLineCount` 是待替换内容
    /// （外部重载、模型驱动整文替换）的行数：替换发生在 chrome 应用
    /// 之后，必须按它而不是旧缓冲区判定，否则大文件会先进入折行布局、
    /// 绕过重排保护；无待替换时用缓冲区 O(1) 行数即可。
    static func resolveSoftWrap(
        enabled: Bool,
        bufferedLineCount: Int,
        incomingLineCount: Int?
    ) -> (isAvailable: Bool, isEffective: Bool) {
        let lineCount = incomingLineCount ?? bufferedLineCount
        let isAvailable = isSoftWrapSupported(lineCount: lineCount)
        return (isAvailable, enabled && isAvailable)
    }

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

    /// Applies the editor scroll geometry for the requested wrap mode. Soft
    /// wrap tracks the panel width and hides horizontal scrolling; disabling
    /// it restores the wide-document viewport used for cheap pane resizing.
    @MainActor
    static func apply(
        to textView: NSTextView,
        in scrollView: NSScrollView,
        softWrap: Bool
    ) {
        guard softWrap else {
            applyUnwrappedScrolling(to: textView, in: scrollView)
            return
        }
        scrollView.hasHorizontalScroller = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        // Autoresizing only reacts to later clip-view bounds changes; pin the
        // frame width now so toggling wraps immediately. When the scroll view
        // has not been laid out yet the clip view takes over once it resizes.
        let contentWidth = max(1, scrollView.contentSize.width)
        textView.setFrameSize(
            NSSize(width: contentWidth, height: textView.frame.height)
        )
    }
}
