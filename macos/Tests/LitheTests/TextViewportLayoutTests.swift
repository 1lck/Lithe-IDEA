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

    @Test
    func disabledSoftWrapReusesTheUnwrappedScrollingGeometry() throws {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isHorizontallyResizable = false

        LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: false)

        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.isHorizontallyResizable)
        let textContainer = try #require(textView.textContainer)
        #expect(!textContainer.widthTracksTextView)
        #expect(textContainer.containerSize.width == CGFloat.greatestFiniteMagnitude)
    }

    @Test
    func enabledSoftWrapTracksPanelWidthAndHidesHorizontalScrolling() throws {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: true)

        #expect(!scrollView.hasHorizontalScroller)
        #expect(!textView.isHorizontallyResizable)
        #expect(textView.isVerticallyResizable)
        #expect(textView.autoresizingMask.contains(.width))
        let textContainer = try #require(textView.textContainer)
        #expect(textContainer.widthTracksTextView)
    }

    @Test
    func togglingBackToUnwrappedRestoresWideDocumentGeometry() throws {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: true)
        LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: false)

        let textContainer = try #require(textView.textContainer)
        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.isHorizontallyResizable)
        #expect(!textContainer.widthTracksTextView)
        #expect(textContainer.containerSize.width == CGFloat.greatestFiniteMagnitude)
    }

    @Test
    func softWrapAvailabilityFallsBackBeyondTheLargeFileLineThreshold() {
        #expect(LitheTextViewportLayout.isSoftWrapSupported(lineCount: 0))
        #expect(LitheTextViewportLayout.isSoftWrapSupported(lineCount: 1))
        #expect(
            LitheTextViewportLayout.isSoftWrapSupported(
                lineCount: LitheTextViewportLayout.softWrapMaximumLineCount
            )
        )
        #expect(
            !LitheTextViewportLayout.isSoftWrapSupported(
                lineCount: LitheTextViewportLayout.softWrapMaximumLineCount + 1
            )
        )
    }
}
