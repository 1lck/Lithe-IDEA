import Foundation
import Testing
@testable import Lithe

@Suite("Editor line editing operations")
struct LineEditingOperationsTests {
    // MARK: - Cmd+/ 行注释切换

    @Test
    func toggleCommentInsertsAtLineStartForUnindentedLine() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "let x = 1",
            selection: NSRange(location: 5, length: 0),
            token: "//"
        )

        #expect(edit?.text == "// let x = 1")
        #expect(edit?.replacedRange == NSRange(location: 0, length: 9))
        // 光标位于插入点之后，随注释符平移保持指向原字符
        #expect(edit?.selection == NSRange(location: 8, length: 0))
    }

    @Test
    func toggleCommentInsertsAfterLeadingIndentation() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "  let x = 1",
            selection: NSRange(location: 0, length: 0),
            token: "//"
        )

        #expect(edit?.text == "  // let x = 1")
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    @Test
    func toggleCommentRemovesTokenAndOneTrailingSpace() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "// let x = 1",
            selection: NSRange(location: 0, length: 0),
            token: "//"
        )

        #expect(edit?.text == "let x = 1")
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    @Test
    func toggleCommentRemovesTokenWithoutTrailingSpace() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "//let x = 1",
            selection: NSRange(location: 4, length: 0),
            token: "//"
        )

        #expect(edit?.text == "let x = 1")
        // 光标原先指向 t（index 4），移除 "//" 后仍指向 t（index 2）
        #expect(edit?.selection == NSRange(location: 2, length: 0))
    }

    @Test
    func toggleCommentUncommentsIndentedLine() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "  // let x = 1",
            selection: NSRange(location: 0, length: 0),
            token: "//"
        )

        #expect(edit?.text == "  let x = 1")
    }

    @Test
    func toggleCommentCommentsMixedSelection() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "a\n// b",
            selection: NSRange(location: 0, length: 6),
            token: "//"
        )

        #expect(edit?.text == "// a\n// // b")
    }

    @Test
    func toggleCommentSkipsBlankLines() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "a\n\nb",
            selection: NSRange(location: 0, length: 4),
            token: "//"
        )

        #expect(edit?.text == "// a\n\n// b")
    }

    @Test
    func toggleCommentExcludesLineWhenSelectionEndsAtLineStart() {
        // 选区 {0,2} 覆盖 "a\n"，终点恰好是第二行行首，该行不计入
        let edit = LineEditingOperations.toggleLineComment(
            in: "a\nb\nc",
            selection: NSRange(location: 0, length: 2),
            token: "//"
        )

        #expect(edit?.text == "// a")
        #expect(edit?.replacedRange == NSRange(location: 0, length: 1))
    }

    @Test
    func toggleCommentPreservesSelectionCoverageAcrossLines() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "a\nb",
            selection: NSRange(location: 0, length: 3),
            token: "//"
        )

        #expect(edit?.text == "// a\n// b")
        #expect(edit?.selection == NSRange(location: 0, length: 9))
    }

    @Test
    func toggleCommentSupportsSQLDashToken() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "SELECT 1",
            selection: NSRange(location: 0, length: 0),
            token: "--"
        )

        #expect(edit?.text == "-- SELECT 1")
    }

    @Test
    func toggleCommentOnAllBlankSelectionIsNoOp() {
        let edit = LineEditingOperations.toggleLineComment(
            in: "  \n\t",
            selection: NSRange(location: 0, length: 4),
            token: "//"
        )

        #expect(edit == nil)
    }

    // MARK: - Cmd+D 复制行 / 选区

    @Test
    func duplicateDuplicatesLineWithTrailingNewlineAndKeepsColumn() {
        let edit = LineEditingOperations.duplicate(
            in: "abc\ndef",
            selection: NSRange(location: 1, length: 0)
        )

        #expect(edit?.text == "abc\n")
        #expect(edit?.replacedRange == NSRange(location: 4, length: 0))
        // 光标落到复制行的同列
        #expect(edit?.selection == NSRange(location: 5, length: 0))
    }

    @Test
    func duplicateDuplicatesLastLineWithoutTrailingNewline() {
        let edit = LineEditingOperations.duplicate(
            in: "abc",
            selection: NSRange(location: 1, length: 0)
        )

        #expect(edit?.text == "\nabc")
        #expect(edit?.replacedRange == NSRange(location: 3, length: 0))
        #expect(edit?.selection == NSRange(location: 5, length: 0))
    }

    @Test
    func duplicateDuplicatesEmptyLine() {
        let edit = LineEditingOperations.duplicate(
            in: "a\n\nb",
            selection: NSRange(location: 2, length: 0)
        )

        #expect(edit?.text == "\n")
        #expect(edit?.replacedRange == NSRange(location: 3, length: 0))
        #expect(edit?.selection == NSRange(location: 3, length: 0))
    }

    @Test
    func duplicateDuplicatesSelectedTextAsIs() {
        let edit = LineEditingOperations.duplicate(
            in: "hello world",
            selection: NSRange(location: 0, length: 5)
        )

        #expect(edit?.text == "hello")
        #expect(edit?.replacedRange == NSRange(location: 5, length: 0))
        // 副本被选中
        #expect(edit?.selection == NSRange(location: 5, length: 5))
    }

    @Test
    func duplicateDuplicatesMultiLineSelection() {
        let edit = LineEditingOperations.duplicate(
            in: "a\nb",
            selection: NSRange(location: 0, length: 3)
        )

        #expect(edit?.text == "a\nb")
        #expect(edit?.replacedRange == NSRange(location: 3, length: 0))
        #expect(edit?.selection == NSRange(location: 3, length: 3))
    }

    @Test
    func duplicatePreservesCRLFSeparator() {
        let edit = LineEditingOperations.duplicate(
            in: "a\r\nb",
            selection: NSRange(location: 1, length: 0)
        )

        #expect(edit?.text == "a\r\n")
        #expect(edit?.replacedRange == NSRange(location: 3, length: 0))
        #expect(edit?.selection == NSRange(location: 4, length: 0))
    }

    // MARK: - Option+Shift+↑/↓ 移动行

    @Test
    func moveUpOnFirstLineIsNoOp() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb",
            selection: NSRange(location: 0, length: 0),
            direction: .up
        )

        #expect(edit == nil)
    }

    @Test
    func moveDownOnLastLineIsNoOp() {
        #expect(
            LineEditingOperations.moveLines(
                in: "a\nb",
                selection: NSRange(location: 2, length: 0),
                direction: .down
            ) == nil
        )
        // 末行带换行符同样没有下一行
        #expect(
            LineEditingOperations.moveLines(
                in: "a\nb\n",
                selection: NSRange(location: 2, length: 0),
                direction: .down
            ) == nil
        )
    }

    @Test
    func moveUpSwapsWithLineAboveAndShiftsCaret() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb\nc",
            selection: NSRange(location: 2, length: 0),
            direction: .up
        )

        #expect(edit?.text == "b\na\n")
        #expect(edit?.replacedRange == NSRange(location: 0, length: 4))
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    @Test
    func moveUpKeepsCaretColumn() {
        // 末行带换行符：块与上一行常规交换
        let edit = LineEditingOperations.moveLines(
            in: "aaa\nb\nccc\n",
            selection: NSRange(location: 8, length: 0),
            direction: .up
        )

        #expect(edit?.text == "ccc\nb\n")
        // 原光标在 ccc 的第 2 列，移动后仍在 ccc 的第 2 列
        #expect(edit?.selection == NSRange(location: 6, length: 0))

        // 末行无换行符：原分隔符移到块与上一行之间
        let lastLineEdit = LineEditingOperations.moveLines(
            in: "aaa\nb\nccc",
            selection: NSRange(location: 8, length: 0),
            direction: .up
        )

        #expect(lastLineEdit?.text == "ccc\nb")
        #expect(lastLineEdit?.selection == NSRange(location: 6, length: 0))
    }

    @Test
    func moveUpMovesMultiLineBlockAsWhole() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb\nc",
            selection: NSRange(location: 2, length: 3),
            direction: .up
        )

        #expect(edit?.text == "b\nc\na")
        // 选区随块整体平移
        #expect(edit?.selection == NSRange(location: 0, length: 3))
    }

    @Test
    func moveUpHandlesLastLineWithoutNewline() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb",
            selection: NSRange(location: 2, length: 0),
            direction: .up
        )

        #expect(edit?.text == "b\na")
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    @Test
    func moveDownHandlesLastLineWithoutNewline() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb",
            selection: NSRange(location: 0, length: 0),
            direction: .down
        )

        #expect(edit?.text == "b\na")
        #expect(edit?.selection == NSRange(location: 2, length: 0))
    }

    @Test
    func moveDownSwapsWithLineBelow() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb\nc",
            selection: NSRange(location: 0, length: 0),
            direction: .down
        )

        #expect(edit?.text == "b\na\n")
        #expect(edit?.selection == NSRange(location: 2, length: 0))
    }

    @Test
    func moveDownExcludesLineWhenSelectionEndsAtLineStart() {
        let edit = LineEditingOperations.moveLines(
            in: "a\nb\nc",
            selection: NSRange(location: 0, length: 2),
            direction: .down
        )

        #expect(edit?.text == "b\na\n")
        #expect(edit?.selection == NSRange(location: 2, length: 2))
    }

    @Test
    func moveUpMovesEmptyLine() {
        let edit = LineEditingOperations.moveLines(
            in: "a\n\nb",
            selection: NSRange(location: 2, length: 0),
            direction: .up
        )

        #expect(edit?.text == "\na\n")
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    @Test
    func movePreservesCRLFSeparator() {
        let edit = LineEditingOperations.moveLines(
            in: "a\r\nb",
            selection: NSRange(location: 3, length: 0),
            direction: .up
        )

        #expect(edit?.text == "b\r\na")
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    // MARK: - 注释符映射

    @Test
    func lineCommentTokenMapsCommonExtensions() {
        #expect(LineEditingOperations.lineCommentToken(forExtension: "swift") == "//")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "Swift") == "//")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "java") == "//")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "ts") == "//")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "py") == "#")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "yaml") == "#")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "properties") == "#")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "sql") == "--")
        #expect(LineEditingOperations.lineCommentToken(forExtension: "lua") == "--")
    }

    @Test
    func lineCommentTokenReturnsNilForUnknownExtension() {
        #expect(LineEditingOperations.lineCommentToken(forExtension: "json") == nil)
        #expect(LineEditingOperations.lineCommentToken(forExtension: "") == nil)
    }
}
