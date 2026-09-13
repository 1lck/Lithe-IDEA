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

    @Test
    func lineCountMatchesTheEditorLineIndexSemantics() {
        // 与 TextLineIndex 一致：\n 或独立 \r 结束一行，CRLF 只算一次，
        // 结尾换行不产生新行，空文本按 1 行。
        #expect(LitheTextViewportLayout.lineCount(of: "") == 1)
        #expect(LitheTextViewportLayout.lineCount(of: "single") == 1)
        #expect(LitheTextViewportLayout.lineCount(of: "a\nb") == 2)
        #expect(LitheTextViewportLayout.lineCount(of: "a\nb\n") == 2)
        #expect(LitheTextViewportLayout.lineCount(of: "\n\n") == 2)
        #expect(LitheTextViewportLayout.lineCount(of: "a\r\nb") == 2)
        #expect(LitheTextViewportLayout.lineCount(of: "a\r\nb\r\n") == 2)
        #expect(LitheTextViewportLayout.lineCount(of: "a\rb") == 2)
        #expect(LitheTextViewportLayout.lineCount(of: "a\r") == 1)
    }

    @Test
    func lineCountCrossesTheLargeFileThresholdInBothDirections() {
        let threshold = LitheTextViewportLayout.softWrapMaximumLineCount
        let atThreshold = String(repeating: "line\n", count: threshold - 1) + "last"
        #expect(LitheTextViewportLayout.lineCount(of: atThreshold) == threshold)
        #expect(LitheTextViewportLayout.isSoftWrapSupported(lineCount: LitheTextViewportLayout.lineCount(of: atThreshold)))

        // 外部重载把小文件换成超限内容：新内容本身要越过阈值。
        let overThreshold = atThreshold + "\nextra"
        #expect(LitheTextViewportLayout.lineCount(of: overThreshold) == threshold + 1)
        #expect(
            !LitheTextViewportLayout.isSoftWrapSupported(
                lineCount: LitheTextViewportLayout.lineCount(of: overThreshold)
            )
        )
    }

    @Test
    func softWrapResolutionJudgesTheIncomingContentOnPendingReplacement() {
        // 外部重载向上跨越：旧缓冲区很小，待显示内容超限 → 不生效。
        let threshold = LitheTextViewportLayout.softWrapMaximumLineCount
        let growCrossing = LitheTextViewportLayout.resolveSoftWrap(
            enabled: true,
            bufferedLineCount: 1,
            incomingLineCount: threshold + 1
        )
        #expect(!growCrossing.isEffective)
        #expect(!growCrossing.isAvailable)

        // 反向下跨越：旧缓冲区超大导致禁用，待显示内容回到阈值内 → 生效。
        let shrinkCrossing = LitheTextViewportLayout.resolveSoftWrap(
            enabled: true,
            bufferedLineCount: threshold + 1,
            incomingLineCount: 1
        )
        #expect(shrinkCrossing.isEffective)
        #expect(shrinkCrossing.isAvailable)

        // 无待替换时按缓冲区行数判定；开关关闭时永不生效。
        let bufferedDecision = LitheTextViewportLayout.resolveSoftWrap(
            enabled: true,
            bufferedLineCount: 1,
            incomingLineCount: nil
        )
        #expect(bufferedDecision.isEffective)
        #expect(bufferedDecision.isAvailable)

        let disabledDecision = LitheTextViewportLayout.resolveSoftWrap(
            enabled: false,
            bufferedLineCount: 1,
            incomingLineCount: 1
        )
        #expect(!disabledDecision.isEffective)
        #expect(disabledDecision.isAvailable)
    }
}
