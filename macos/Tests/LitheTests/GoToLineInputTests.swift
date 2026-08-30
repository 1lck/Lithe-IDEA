import Foundation
import Testing
@testable import Lithe

struct GoToLineInputTests {
    @Test
    func parsesLineOnlyInputAsZeroBasedLineWithZeroColumn() {
        // "120" means 1-based line 120, line start; converted to 0-based here.
        #expect(GoToLineInput.parse("120") == GoToLineInput(line: 119, column: 0))
        #expect(GoToLineInput.parse("1") == GoToLineInput(line: 0, column: 0))
    }

    @Test
    func parsesLineAndColumnInput() {
        #expect(
            GoToLineInput.parse("120:35")
                == GoToLineInput(line: 119, column: 34, hasExplicitColumn: true)
        )
    }

    @Test
    func marksExplicitColumnOnlyForColonInput() {
        // 只有显式输入了列号才标记 hasExplicitColumn：行号跳转整行选中，
        // 行:列跳转把 caret 放到该列
        #expect(GoToLineInput.parse("120")?.hasExplicitColumn == false)
        #expect(GoToLineInput.parse("120:35")?.hasExplicitColumn == true)
        #expect(GoToLineInput.parse(" 120 : 35 ")?.hasExplicitColumn == true)
    }

    @Test
    func toleratesWhitespaceAroundAndBetweenNumbers() {
        #expect(GoToLineInput.parse("  120 ") == GoToLineInput(line: 119, column: 0))
        #expect(
            GoToLineInput.parse("12 : 34")
                == GoToLineInput(line: 11, column: 33, hasExplicitColumn: true)
        )
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
        // In 1-based input, zero and negatives are invalid values.
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
        // Columns are counted in UTF-16 units, matching the editor caret's
        // utf16Column convention.
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
        // An empty document (0 lines) only ever addresses the document start.
        #expect(GoToLineInput.clamped(line: 4, column: 9, in: "") == GoToLineInput(line: 0, column: 0))
    }

    @Test
    func clampsToTrailingEmptyLineAfterFinalNewline() {
        // "a\n" has an addressable second line (the trailing empty line).
        #expect(GoToLineInput.clamped(line: 9, column: 3, in: "a\n") == GoToLineInput(line: 1, column: 0))
        #expect(GoToLineInput.clamped(line: 9, column: 3, in: "a\nb") == GoToLineInput(line: 1, column: 1))
    }

    @Test
    func clampsLineAndColumnInCRLFContent() {
        // CRLF 终止符不计入上一行的列上限
        let content = "first\r\nsecond\r\nthird"
        #expect(GoToLineInput.clamped(line: 0, column: 99, in: content) == GoToLineInput(line: 0, column: 5))
        #expect(GoToLineInput.clamped(line: 1, column: 99, in: content) == GoToLineInput(line: 1, column: 6))
        #expect(GoToLineInput.clamped(line: 2, column: 1, in: content) == GoToLineInput(line: 2, column: 1))
        #expect(GoToLineInput.clamped(line: 9, column: 0, in: content) == GoToLineInput(line: 2, column: 0))
    }

    @Test
    func clampsLineAndColumnInCRonlyContent() {
        // CR-only 换行与编辑器 TextLineIndex 的行索引规则一致
        let content = "a\rb"
        #expect(GoToLineInput.clamped(line: 0, column: 99, in: content) == GoToLineInput(line: 0, column: 1))
        #expect(GoToLineInput.clamped(line: 1, column: 0, in: content) == GoToLineInput(line: 1, column: 0))
        #expect(GoToLineInput.clamped(line: 9, column: 0, in: content) == GoToLineInput(line: 1, column: 0))
    }

    @Test
    func preservesExplicitColumnThroughClamping() {
        // 收敛不改变显式列号标记
        let parsed = GoToLineInput.parse("99:2")
        // 与 AppModel.goToLine 一致：把解析出的显式列号标记一并传入收敛
        let clamped = parsed.map {
            GoToLineInput.clamped(
                line: $0.line,
                column: $0.column,
                hasExplicitColumn: $0.hasExplicitColumn,
                in: "a\nb"
            )
        }
        #expect(clamped?.hasExplicitColumn == true)
        #expect(clamped == GoToLineInput(line: 1, column: 1, hasExplicitColumn: true))
    }

    @Test
    func clampsColumnUsingUTF16LengthOfEmojiLine() {
        // An emoji spans two UTF-16 units, so convergence counts UTF-16
        // length rather than character count.
        let content = "a\u{1F600}b"
        #expect(GoToLineInput.clamped(line: 0, column: 3, in: content) == GoToLineInput(line: 0, column: 3))
        #expect(GoToLineInput.clamped(line: 0, column: 4, in: content) == GoToLineInput(line: 0, column: 4))
        #expect(GoToLineInput.clamped(line: 0, column: 5, in: content) == GoToLineInput(line: 0, column: 4))
    }
}
