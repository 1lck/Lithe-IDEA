import Foundation
import LitheCoreContracts
@testable import LitheDebugModule
import Testing

struct DebugConsoleCompletionTests {
    private func item(
        _ text: String,
        label: String? = nil,
        start: Int? = nil,
        length: Int? = nil
    ) -> DebugCompletionItem {
        DebugCompletionItem(
            label: label ?? text,
            text: text,
            detail: nil,
            kind: nil,
            start: start,
            length: length
        )
    }

    private func suggestions(
        _ text: String,
        caret: Int? = nil,
        adapter: [DebugCompletionItem] = [],
        declared: [DebugConsoleCommand] = []
    ) -> [DebugConsoleCompletion.Suggestion] {
        DebugConsoleCompletion.suggestions(
            text: text,
            caret: caret ?? text.utf16.count,
            adapterItems: adapter,
            declared: declared
        )
    }

    @Test
    func splitsAdapterLabelsIntoNameAndDescription() throws {
        let result = suggestions("fra", adapter: [item(
            "frame",
            label: "frame -- Commands for selecting and examining the current thread's stack frames."
        )])
        let first = try #require(result.first)
        #expect(first.name == "frame")
        #expect(first.detail == "Commands for selecting and examining the current thread's stack frames.")
        #expect(first.insertion == "frame")
        #expect(first.replacementStart == 0)
        #expect(first.replacementLength == 3)
    }

    @Test
    func replacesTheTypedTailWhenTheAdapterGivesNoRange() throws {
        let option = try #require(suggestions("breakpoint set --n", adapter: [item("--name")]).first)
        #expect(option.replacementStart == 15)
        #expect(option.replacementLength == 3)

        let variable = try #require(suggestions("p tot", adapter: [item("total")]).first)
        #expect(variable.replacementStart == 2)
        #expect(variable.replacementLength == 3)

        let shouting = try #require(suggestions("P TOT", adapter: [item("total")]).first)
        #expect(shouting.replacementStart == 2)
        #expect(shouting.replacementLength == 3)
    }

    @Test
    func insertsAtTheCaretWhenNothingTypedMatches() throws {
        let result = try #require(suggestions("frame ", adapter: [item("select")]).first)
        #expect(result.replacementStart == 6)
        #expect(result.replacementLength == 0)
        #expect(DebugConsoleCompletion.apply(result, to: "frame ").text == "frame select")
    }

    @Test
    func prefersTheRangeTheAdapterReturned() throws {
        let result = try #require(suggestions("print foo.ba", adapter: [item("bar", start: 10, length: 2)]).first)
        #expect(result.replacementStart == 10)
        #expect(result.replacementLength == 2)
        #expect(DebugConsoleCompletion.apply(result, to: "print foo.ba").text == "print foo.bar")
    }

    @Test
    func countsUTF16UnitsAroundSurrogatePairs() throws {
        let tail = try #require(suggestions("p 😀x", adapter: [item("x1")]).first)
        #expect(tail.replacementStart == 4)
        #expect(tail.replacementLength == 1)

        let wide = try #require(suggestions("p 😀x", adapter: [item("😀xyz")]).first)
        #expect(wide.replacementStart == 2)
        #expect(wide.replacementLength == 3)
        let applied = DebugConsoleCompletion.apply(wide, to: "p 😀x")
        #expect(applied.text == "p 😀xyz")
        #expect(applied.caret == applied.text.utf16.count)
    }

    @Test
    func clampsOutOfRangeCaretAndAdapterRanges() throws {
        let beyond = suggestions("fra", caret: 99, adapter: [item("frame")])
        #expect(beyond.first?.replacementLength == 3)

        let wild = try #require(suggestions("fra", adapter: [item("frame", start: 2, length: 40)]).first)
        #expect(wild.replacementStart == 2)
        #expect(wild.replacementLength == 1)
        #expect(DebugConsoleCompletion.apply(wild, to: "fra").text == "frframe")
    }

    @Test
    func completesDeclaredCommandsFromTheFirstWord() throws {
        let declared = [
            DebugConsoleCommand(name: "breakpoint set", detail: "Set a breakpoint"),
            DebugConsoleCommand(name: "frame variable", detail: nil)
        ]
        let result = try #require(suggestions("breakpoint s", declared: declared).first)
        #expect(result.name == "breakpoint set")
        #expect(result.detail == "Set a breakpoint")
        #expect(result.replacementStart == 0)
        #expect(result.replacementLength == 12)

        let indented = try #require(suggestions("  frame v", declared: declared).first)
        #expect(indented.replacementStart == 2)
        #expect(indented.replacementLength == 7)

        #expect(suggestions("BREAK", declared: declared).count == 1)
        #expect(suggestions("set", declared: declared).isEmpty)
        #expect(suggestions("frame variable", declared: declared).isEmpty)
        #expect(suggestions("   ", declared: declared).isEmpty)
    }

    @Test
    func listsAdapterProposalsFirstWithoutDuplicates() {
        let result = suggestions(
            "break",
            adapter: [item("breakpoint set"), item("br"), item("")],
            declared: [
                DebugConsoleCommand(name: "breakpoint set", detail: "declared"),
                DebugConsoleCommand(name: "breakpoint list", detail: nil)
            ]
        )
        #expect(result.map(\.insertion) == ["breakpoint set", "br", "breakpoint list"])
        #expect(result.first?.detail == nil)
    }

    @Test
    func capsTheListLength() {
        let many = (0..<200).map { item("command\($0)") }
        #expect(suggestions("c", adapter: many).count == DebugConsoleCompletion.maximumSuggestions)
    }

    @Test
    func extendsTheTypedWordToTheCommonStart() throws {
        let result = suggestions("fr", adapter: [item("frame"), item("framebuffer"), item("frag")])
        let common = try #require(DebugConsoleCompletion.commonExtension(of: result))
        #expect(common.insertion == "fra")
        #expect(DebugConsoleCompletion.apply(common, to: "fr").text == "fra")

        #expect(DebugConsoleCompletion.commonExtension(of: suggestions("x", adapter: [item("alpha"), item("beta")])) == nil)
        #expect(DebugConsoleCompletion.commonExtension(of: []) == nil)

        let mixed = suggestions("p a", adapter: [item("alpha", start: 2, length: 1), item("alpine", start: 0, length: 3)])
        #expect(DebugConsoleCompletion.commonExtension(of: mixed) == nil)
    }

    @Test
    func cutsALongAdapterDescriptionAtItsFirstLine() throws {
        let label = "frame -- Commands for frames.\n\nLong help the popup row cannot show."
        let first = try #require(suggestions("fra", adapter: [item("frame", label: label)]).first)
        #expect(first.detail == "Commands for frames.")
    }

    @Test
    func putsTheCommandPrefixBeforeTheLineSentToTheAdapter() {
        let sent = DebugConsoleCompletion.adapterRequest(text: "fr", caret: 2, commandPrefix: "`")
        #expect(sent.text == "`fr")
        #expect(sent.caret == 3)
        #expect(sent.shift == 1)

        // A user who typed the prefix already is not given a second one.
        let typed = DebugConsoleCompletion.adapterRequest(text: "`fr", caret: 3, commandPrefix: "`")
        #expect(typed.text == "`fr")
        #expect(typed.shift == 0)

        let none = DebugConsoleCompletion.adapterRequest(text: "fr", caret: 2, commandPrefix: nil)
        #expect(none.text == "fr")
        #expect(none.shift == 0)
    }

    @Test
    func movesAdapterRangesBackOntoTheTypedLine() {
        let items = [
            item("frame", start: 1, length: 2),
            item("breakpoint", start: 0, length: 3),
            item("thread")
        ]
        let moved = DebugConsoleCompletion.restoring(items, shift: 1)
        #expect(moved.map(\.start) == [0, 0, nil])
        // A range that began inside the prefix keeps only the part inside the line.
        #expect(moved.map(\.length) == [2, 2, nil])
        #expect(DebugConsoleCompletion.restoring(items, shift: 0) == items)
    }
}
