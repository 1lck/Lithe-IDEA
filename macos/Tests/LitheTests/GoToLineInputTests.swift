import Foundation
import Testing
@testable import Lithe

struct GoToLineInputTests {
    @Test
    func parsesLineOnlyInputAsZeroBasedLineWithZeroColumn() {
        // “120”表示第 120 行行首，内部转换为 0-based
        #expect(GoToLineInput.parse("120") == GoToLineInput(line: 119, column: 0))
        #expect(GoToLineInput.parse("1") == GoToLineInput(line: 0, column: 0))
    }

    @Test
    func parsesLineAndColumnInput() {
        #expect(GoToLineInput.parse("120:35") == GoToLineInput(line: 119, column: 34))
    }

    @Test
    func toleratesWhitespaceAroundAndBetweenNumbers() {
        #expect(GoToLineInput.parse("  120 ") == GoToLineInput(line: 119, column: 0))
        #expect(GoToLineInput.parse("12 : 34") == GoToLineInput(line: 11, column: 33))
    }

    @Test
    func rejectsEmptyNonNumericAndMultiColonInput() {
        #expect(GoToLineInput.parse("") == nil)
        #expect(GoToLineInput.parse("   ") == nil)
        #expect(GoToLineInput.parse("abc") == nil)
        #expect(GoToLineInput.parse("12abc") == nil)
        #expect(GoToLineInput.parse("1:2:3") == nil)
        #expect(GoToLineInput.parse("120:") == nil)
        #expect(GoToLineInput.parse(":35") == nil)
    }

    @Test
    func rejectsZeroAndNegativeNumbers() {
        // 1-based 输入里 0 与负数都是非法值
        #expect(GoToLineInput.parse("0") == nil)
        #expect(GoToLineInput.parse("-1") == nil)
        #expect(GoToLineInput.parse("0:5") == nil)
        #expect(GoToLineInput.parse("5:0") == nil)
        #expect(GoToLineInput.parse("5:-2") == nil)
    }

    @Test
    func keepsInBoundsLineAndColumnUnchanged() {
        let content = "first\nsecond line\nthird"
        #expect(GoToLineInput.clamped(line: 0, column: 2, in: content) == GoToLineInput(line: 0, column: 2))
        #expect(GoToLineInput.clamped(line: 2, column: 4, in: content) == GoToLineInput(line: 2, column: 4))
    }

    @Test
    func clampsOutOfRangeLineToLastLine() {
        let content = "first\nsecond line\nthird"
        #expect(GoToLineInput.clamped(line: 99, column: 0, in: content) == GoToLineInput(line: 2, column: 0))
    }

    @Test
    func clampsOutOfRangeColumnToLineEnd() {
        // 列按 UTF-16 单元计数，与编辑器 caret 的 utf16Column 口径一致
        let content = "first\nsecond line\nthird"
        #expect(GoToLineInput.clamped(line: 1, column: 99, in: content) == GoToLineInput(line: 1, column: 11))
    }

    @Test
    func clampsNegativeValuesToDocumentStart() {
        let content = "first\nsecond line\nthird"
        #expect(GoToLineInput.clamped(line: -3, column: -1, in: content) == GoToLineInput(line: 0, column: 0))
    }

    @Test
    func clampsAnyInputInEmptyDocumentToOrigin() {
        // 空文档（0 行）时输入任何行号都只定位到文档开头
        #expect(GoToLineInput.clamped(line: 4, column: 9, in: "") == GoToLineInput(line: 0, column: 0))
    }

    @Test
    func clampsToTrailingEmptyLineAfterFinalNewline() {
        // “a\n”在编辑器里存在可定位的第 2 行（末尾空行）
        #expect(GoToLineInput.clamped(line: 9, column: 3, in: "a\n") == GoToLineInput(line: 1, column: 0))
        #expect(GoToLineInput.clamped(line: 9, column: 3, in: "a\nb") == GoToLineInput(line: 1, column: 1))
    }

    @Test
    func clampsColumnUsingUTF16LengthOfEmojiLine() {
        // emoji 占 2 个 UTF-16 单元，列收敛按 UTF-16 长度而非字符数
        let content = "a\u{1F600}b"
        #expect(GoToLineInput.clamped(line: 0, column: 3, in: content) == GoToLineInput(line: 0, column: 3))
        #expect(GoToLineInput.clamped(line: 0, column: 4, in: content) == GoToLineInput(line: 0, column: 4))
        #expect(GoToLineInput.clamped(line: 0, column: 5, in: content) == GoToLineInput(line: 0, column: 4))
    }
}
