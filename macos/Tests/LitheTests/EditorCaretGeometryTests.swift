import AppKit
import Testing
@testable import Lithe

/// Regression coverage for #385: custom caret drawing must reach the true end
/// of the last line and the extra line after a trailing newline.
@Suite("Editor caret geometry")
struct EditorCaretGeometryTests {
    @MainActor
    @Test
    func caretAfterLastCharacterSitsPastTheFinalGlyphWhenFileHasNoTrailingNewline() throws {
        let textView = makeLaidOutEditor(text: "DP_LOAD_BALANCE_PORT=18081")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let length = textView.string.utf16.count
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        let onLastCharacter = EditorCaretGeometry.rect(
            at: length - 1,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let atDocumentEnd = EditorCaretGeometry.rect(
            at: length,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(atDocumentEnd.minX > onLastCharacter.minX)
        #expect(abs(atDocumentEnd.minY - onLastCharacter.minY) < 0.5)
        #expect(atDocumentEnd.width == EditorLayoutMetrics.caretWidth)
    }

    @MainActor
    @Test
    func caretOnLineEndingSitsAfterVisibleLineContent() throws {
        let textView = makeLaidOutEditor(text: "first\nsecond\n")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let source = textView.string as NSString
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        // Index of the newline after "first"
        let firstNewline = source.range(of: "\n").location
        let caretOnNewline = EditorCaretGeometry.rect(
            at: firstNewline,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let caretOnLastLetter = EditorCaretGeometry.rect(
            at: firstNewline - 1,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(caretOnNewline.minX > caretOnLastLetter.minX)
        #expect(abs(caretOnNewline.minY - caretOnLastLetter.minY) < 0.5)
    }

    @MainActor
    @Test
    func caretAtDocumentEndAfterTrailingNewlineUsesExtraLineFragment() throws {
        let textView = makeLaidOutEditor(text: "only\n")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let length = textView.string.utf16.count
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        let endCaret = EditorCaretGeometry.rect(
            at: length,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let contentCaret = EditorCaretGeometry.rect(
            at: 0,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(endCaret.minY > contentCaret.minY)
        #expect(layoutManager.extraLineFragmentUsedRect.height > 0)
    }

    @MainActor
    @Test
    func caretOnCRLFLineEndingStillSitsAfterVisibleContent() throws {
        let textView = makeLaidOutEditor(text: "alpha\r\nbeta")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let source = textView.string as NSString
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)
        let crIndex = source.range(of: "\r").location

        let caretOnCR = EditorCaretGeometry.rect(
            at: crIndex,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let caretOnLastLetter = EditorCaretGeometry.rect(
            at: crIndex - 1,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let caretOnLF = EditorCaretGeometry.rect(
            at: crIndex + 1,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(caretOnCR.minX > caretOnLastLetter.minX)
        #expect(abs(caretOnLF.minX - caretOnCR.minX) < 0.5)
        #expect(abs(caretOnLF.minY - caretOnCR.minY) < 0.5)
    }

    @MainActor
    @Test
    func emptyDocumentCaretUsesFallbackLineHeight() throws {
        let textView = makeLaidOutEditor(text: "")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        let caret = EditorCaretGeometry.rect(
            at: 0,
            sourceLength: 0,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(caret.height >= fallback)
        #expect(caret.width == EditorLayoutMetrics.caretWidth)
    }

    @MainActor
    private func makeLaidOutEditor(text: String) -> CodeTextView {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        textView.font = LitheTheme.editorFont(size: 13)
        textView.defaultParagraphStyle = LitheTheme.editorParagraphStyle
        textView.string = text
        textView.textContainerInset = NSSize(width: EditorLayoutMetrics.leadingInset, height: 0)
        textView.textContainer?.lineFragmentPadding = EditorLayoutMetrics.lineFragmentPadding
        if let textStorage = textView.textStorage, textStorage.length > 0 {
            textStorage.addAttributes(
                [
                    .font: textView.font as Any,
                    .paragraphStyle: textView.defaultParagraphStyle as Any
                ],
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        textView.layoutManager?.delegate = textView
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        return textView
    }
}
