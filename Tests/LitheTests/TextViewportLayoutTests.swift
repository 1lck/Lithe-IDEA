import AppKit
import Testing
@testable import Lithe

@Suite("Text viewport layout")
@MainActor
struct TextViewportLayoutTests {
    @Test
    func unwrappedViewportKeepsDocumentWidthIndependentFromViewport() throws {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        LitheTextViewportLayout.applyUnwrappedScrolling(to: textView, in: scrollView)

        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.isHorizontallyResizable)
        let textContainer = try #require(textView.textContainer)
        #expect(!textContainer.widthTracksTextView)
        #expect(textContainer.containerSize.width == CGFloat.greatestFiniteMagnitude)
    }
}
