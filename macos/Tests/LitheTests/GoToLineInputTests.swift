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
    func clampsColumnUsingUTF16LengthOfEmojiLine() {
        // An emoji spans two UTF-16 units, so convergence counts UTF-16
        // length rather than character count.
        let content = "a\u{1F600}b"
        #expect(GoToLineInput.clamped(line: 0, column: 3, in: content) == GoToLineInput(line: 0, column: 3))
        #expect(GoToLineInput.clamped(line: 0, column: 4, in: content) == GoToLineInput(line: 0, column: 4))
        #expect(GoToLineInput.clamped(line: 0, column: 5, in: content) == GoToLineInput(line: 0, column: 4))
    }
}
