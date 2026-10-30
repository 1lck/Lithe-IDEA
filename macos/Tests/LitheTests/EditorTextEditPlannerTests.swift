import Foundation
import Testing
@testable import Lithe

private func at(_ line: Int, _ column: Int) -> EditorTextPosition { EditorTextPosition(line: line, column: column) }
private func edit(_ start: EditorTextPosition, _ end: EditorTextPosition, _ text: String) -> EditorTextEdit {
    EditorTextEdit(range: EditorTextRange(start: start, end: end), text: text)
}
private func applying(_ edits: [EditorTextEdit], to text: String) throws -> String {
    EditorTextEditPlanner.apply(try EditorTextEditPlanner.plan(edits, in: EditorTextLineIndex(text)), to: text)
}

@Suite("Plugin text edit planning")
struct EditorTextEditPlannerTests {
    @Test func emojiColumnsCountUTF16CodeUnits() throws {
        // "😀" occupies columns 2 and 3; "b" is column 4.
        #expect(try applying([edit(at(1, 2), at(1, 4), "X")], to: "a😀b") == "aXb")
        #expect(EditorTextLineIndex("a😀b").offset(of: at(1, 5)) == 4)
        #expect(throws: EditorDocumentServiceError.invalidRange(editIndex: 0, reason: .splitsSurrogatePair)) {
            try EditorTextEditPlanner.plan([edit(at(1, 3), at(1, 4), "")], in: EditorTextLineIndex("a😀b"))
        }
    }

    @Test func combiningMarksAreSeparateCodeUnits() throws {
        // "é" written as e + U+0301 spans columns 1...2; the mark alone is addressable.
        #expect(try applying([edit(at(1, 2), at(1, 3), "")], to: "e\u{301}x") == "ex")
        #expect(try applying([edit(at(1, 1), at(1, 3), "E")], to: "e\u{301}x") == "Ex")
    }

    @Test func chineseCharactersAreOneColumnEach() throws {
        #expect(try applying([edit(at(1, 1), at(1, 2), "英")], to: "中文") == "英文")
        #expect(EditorTextLineIndex("中文").offset(of: at(1, 3)) == 2)
        #expect(EditorTextLineIndex("中文").offset(of: at(1, 4)) == nil)
    }

    @Test func crlfIsOneLineBreakAndInsertedBreaksFollowTheDocument() throws {
        let index = EditorTextLineIndex("a\r\nb")
        #expect(index.lineEnding == .crlf)
        #expect(index.lineCount == 2)
        #expect(index.offset(of: at(2, 1)) == 3)
        // Column 3 of line 1 would sit between CR and LF.
        #expect(index.offset(of: at(1, 3)) == nil)
        let plan = try EditorTextEditPlanner.plan([edit(at(2, 1), at(2, 1), "x\ny\r\n")], in: index)
        #expect(plan.first?.normalizedText == "x\ny\n")
        #expect(EditorTextEditPlanner.apply(plan, to: "a\r\nb") == "a\r\nx\r\ny\r\nb")
        #expect(index.position(at: 3) == at(2, 1))
    }

    @Test func lineEndingDetection() {
        #expect(EditorTextLineIndex("plain").lineEnding == .lf)
        #expect(EditorTextLineIndex("a\rb").lineEnding == .cr)
        let mixed = EditorTextLineIndex("a\nb\r\nc")
        #expect(mixed.lineEnding == .mixed)
        #expect(mixed.insertionSeparator == "\n")
        #expect(mixed.lineCount == 3)
    }

    @Test func endOfLineAndEndOfDocumentAreValid() throws {
        #expect(try applying([edit(at(1, 3), at(1, 3), "!"), edit(at(2, 1), at(2, 1), "?")], to: "ab\n") == "ab!\n?")
    }

    @Test func rejectsPositionsOutsideTheDocument() {
        let index = EditorTextLineIndex("ab\ncd")
        for position in [at(0, 1), at(3, 1), at(1, 0), at(1, 4)] {
            #expect(throws: EditorDocumentServiceError.rangeOutOfBounds(editIndex: 1)) {
                try EditorTextEditPlanner.plan([edit(at(1, 1), at(1, 1), ""), edit(position, position, "x")], in: index)
            }
        }
    }

    @Test func rejectsReversedRanges() {
        #expect(throws: EditorDocumentServiceError.invalidRange(editIndex: 0, reason: .reversed)) {
            try EditorTextEditPlanner.plan([edit(at(1, 3), at(1, 1), "")], in: EditorTextLineIndex("abc"))
        }
    }

    @Test func rejectsOverlapAndReportsCallerIndices() {
        #expect(throws: EditorDocumentServiceError.overlappingRanges(editIndex: 0, otherEditIndex: 1)) {
            try EditorTextEditPlanner.plan([edit(at(1, 3), at(1, 5), ""), edit(at(1, 1), at(1, 4), "")],
                                           in: EditorTextLineIndex("abcdef"))
        }
        // An insertion strictly inside a replaced range also overlaps.
        #expect(throws: EditorDocumentServiceError.overlappingRanges(editIndex: 0, otherEditIndex: 1)) {
            try EditorTextEditPlanner.plan([edit(at(1, 1), at(1, 4), ""), edit(at(1, 2), at(1, 2), "x")],
                                           in: EditorTextLineIndex("abcdef"))
        }
    }

    @Test func adjacentRangesAndSamePositionInsertsAreAllowed() throws {
        #expect(try applying([edit(at(1, 2), at(1, 3), "B"), edit(at(1, 1), at(1, 2), "A")], to: "ab") == "AB")
        #expect(try applying([edit(at(1, 1), at(1, 1), "x"), edit(at(1, 1), at(1, 1), "y")], to: "z") == "xyz")
    }

    @Test func multiLineEditsInMultiSelectionBatch() throws {
        let text = "one\ntwo\nthree"
        let edits = [edit(at(3, 1), at(3, 6), "3"), edit(at(1, 1), at(1, 4), "1"), edit(at(1, 4), at(2, 4), "")]
        #expect(try applying(edits, to: text) == "1\n3")
    }
}
