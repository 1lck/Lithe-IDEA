import Foundation
import Testing
@testable import Lithe

/// 回归测试：Go to Line 跳转后编辑器的最终 caret/selection 范围。
/// 只输入行号时整行选中（行尾终止符不计入选区）；显式输入列号时
/// caret 落在该列；行索引遵循 LF、CRLF、CR 三种终止符规则。
struct GoToLineSelectionTests {
    private let content = "first\nsecond line\nthird" as NSString

    @Test
    func placesZeroLengthCaretAtExplicitColumn() {
        // "120:35" 类输入：caret 落在第 2 行（0-based 1）第 4 列
        let range = GoToLineSelection.targetRange(
            line: 1,
            utf16Column: 4,
            selectsWholeLine: false,
            in: content
        )
        #expect(range == NSRange(location: 10, length: 0))
    }

    @Test
    func selectsWholeLineContentWithoutTerminator() {
        let range = GoToLineSelection.targetRange(
            line: 0,
            utf16Column: 0,
            selectsWholeLine: true,
            in: content
        )
        #expect(range == NSRange(location: 0, length: 5))
    }

    @Test
    func clampsColumnBeyondLineEndToLastColumn() {
        let range = GoToLineSelection.targetRange(
            line: 1,
            utf16Column: 99,
            selectsWholeLine: false,
            in: content
        )
        // "second line" 长 11，行起点 6 → caret 在行尾（UTF-16 位置 17）
        #expect(range == NSRange(location: 17, length: 0))
    }

    @Test
    func clampsOutOfRangeLineToLastLine() {
        let range = GoToLineSelection.targetRange(
            line: 99,
            utf16Column: 0,
            selectsWholeLine: true,
            in: content
        )
        // 最后一行 "third" 从 18 开始，长 5
        #expect(range == NSRange(location: 18, length: 5))
    }

    @Test
    func selectsWholeLineInCRLFContentWithoutCarriageReturn() {
        // CRLF 文件的整行选区不能把 \r 带进来
        let crlf = "ab\r\ncd" as NSString
        let range = GoToLineSelection.targetRange(
            line: 0,
            utf16Column: 0,
            selectsWholeLine: true,
            in: crlf
        )
        #expect(range == NSRange(location: 0, length: 2))

        let caret = GoToLineSelection.targetRange(
            line: 0,
            utf16Column: 99,
            selectsWholeLine: false,
            in: crlf
        )
        // caret 收敛到行内容末尾（\r 之前）
        #expect(caret == NSRange(location: 2, length: 0))
    }

    @Test
    func indexesCRonlyContentByLine() {
        // CR-only 换行同样按行定位
        let crOnly = "a\rb" as NSString
        let wholeLine = GoToLineSelection.targetRange(
            line: 1,
            utf16Column: 0,
            selectsWholeLine: true,
            in: crOnly
        )
        #expect(wholeLine == NSRange(location: 2, length: 1))

        let caret = GoToLineSelection.targetRange(
            line: 0,
            utf16Column: 0,
            selectsWholeLine: false,
            in: crOnly
        )
        #expect(caret == NSRange(location: 0, length: 0))
    }

    @Test
    func clampsAnyTargetInEmptyDocumentToOrigin() {
        let empty = "" as NSString
        let wholeLine = GoToLineSelection.targetRange(
            line: 4,
            utf16Column: 9,
            selectsWholeLine: true,
            in: empty
        )
        #expect(wholeLine == NSRange(location: 0, length: 0))

        let caret = GoToLineSelection.targetRange(
            line: 4,
            utf16Column: 9,
            selectsWholeLine: false,
            in: empty
        )
        #expect(caret == NSRange(location: 0, length: 0))
    }

    @Test
    func trailingNewlineYieldsEmptyFinalLineSelection() {
        // "a\n" 存在可定位的第 2 行（末尾空行），整行选区为零长度
        let trailing = "a\n" as NSString
        let range = GoToLineSelection.targetRange(
            line: 9,
            utf16Column: 0,
            selectsWholeLine: true,
            in: trailing
        )
        #expect(range == NSRange(location: 2, length: 0))
    }

    @Test
    func clampsNegativeLineAndColumnToOrigin() {
        let range = GoToLineSelection.targetRange(
            line: -3,
            utf16Column: -1,
            selectsWholeLine: false,
            in: content
        )
        #expect(range == NSRange(location: 0, length: 0))
    }
}
