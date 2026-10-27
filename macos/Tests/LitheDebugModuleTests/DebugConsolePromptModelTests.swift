import Foundation
@testable import LitheDebugModule
import Testing

@MainActor
struct DebugConsolePromptModelTests {
    private typealias Suggestion = DebugConsoleCompletion.Suggestion

    /// Proposes `insertion` for the whole typed word, as an adapter that gives its range does.
    private func suggestion(_ insertion: String, replacing length: Int, detail: String? = nil) -> Suggestion {
        Suggestion(
            name: insertion,
            detail: detail,
            kind: nil,
            replacementStart: 0,
            replacementLength: length,
            insertion: insertion
        )
    }

    /// A prompt whose provider answers at once from `table`, keyed by the typed line.
    private func prompt(_ table: [String: [String]]) -> DebugConsolePromptModel {
        DebugConsolePromptModel { text, _, completion in
            completion((table[text] ?? []).map { suggestion($0, replacing: text.utf16.count) })
        }
    }

    @Test
    func typingOpensThePopupAndABlankLineClosesIt() {
        let prompt = prompt(["fr": ["frame", "frame variable"]])

        prompt.textDidChange("fr", caret: 2)
        #expect(prompt.isPopupOpen)
        #expect(prompt.suggestions.map(\.insertion) == ["frame", "frame variable"])
        #expect(prompt.selectedIndex == 0)

        prompt.textDidChange("  ", caret: 2)
        #expect(!prompt.isPopupOpen)
    }

    @Test
    func proposalsThatLeaveTheLineUnchangedAreNotListed() {
        let prompt = prompt(["help": ["help"], "he": ["help", "he"]])

        prompt.textDidChange("help", caret: 4)
        #expect(!prompt.isPopupOpen)

        prompt.textDidChange("he", caret: 2)
        #expect(prompt.suggestions.map(\.insertion) == ["help"])
    }

    @Test
    func arrowKeysWrapAndFallThroughWhenTheListIsClosed() {
        let prompt = prompt(["b": ["breakpoint", "bt", "b main"]])
        #expect(!prompt.moveSelection(by: 1))

        prompt.textDidChange("b", caret: 1)
        #expect(prompt.moveSelection(by: -1))
        #expect(prompt.selectedIndex == 2)
        #expect(prompt.moveSelection(by: 1))
        #expect(prompt.selectedIndex == 0)
        #expect(prompt.moveSelection(by: 1))
        #expect(prompt.selectedSuggestion?.insertion == "bt")
    }

    @Test
    func acceptingTheHighlightedSuggestionFillsTheLineAndClosesThePopup() throws {
        let prompt = prompt(["fra": ["frame", "frame variable"]])
        prompt.textDidChange("fra", caret: 3)
        prompt.moveSelection(by: 1)

        let filled = try #require(prompt.acceptSelected(into: "fra"))
        #expect(filled.text == "frame variable")
        #expect(filled.caret == 14)
        #expect(!prompt.isPopupOpen)
        #expect(prompt.acceptSelected(into: filled.text) == nil)
    }

    @Test
    func enterTakesARowOnlyAfterTheHighlightMoved() throws {
        let prompt = prompt(["fra": ["frame", "frame variable"]])
        prompt.textDidChange("fra", caret: 3)
        #expect(prompt.acceptChosen(into: "fra") == nil)
        #expect(prompt.isPopupOpen)

        prompt.moveSelection(by: 1)
        let filled = try #require(prompt.acceptChosen(into: "fra"))
        #expect(filled.text == "frame variable")
        #expect(!prompt.isSelectionChosen)

        prompt.textDidChange("fra", caret: 3)
        prompt.select(at: 0)
        #expect(prompt.isSelectionChosen)
        prompt.textDidChange("fra", caret: 3)
        #expect(!prompt.isSelectionChosen)
    }

    @Test
    func tabExtendsTheSharedPrefixBeforeChoosing() {
        let prompt = prompt([
            "f": ["frame select", "frame variable"],
            "frame ": ["frame select", "frame variable"]
        ])
        prompt.textDidChange("f", caret: 1)

        #expect(prompt.tab(text: "f", caret: 1) == .replace(text: "frame ", caret: 6))
        // The list is asked again for the longer line instead of closing.
        #expect(prompt.isPopupOpen)
        #expect(prompt.suggestions.map(\.insertion) == ["frame select", "frame variable"])
    }

    @Test
    func tabFillsTheHighlightedSuggestionWhenNothingMoreIsShared() {
        let prompt = prompt(["b": ["breakpoint", "bt"]])
        prompt.textDidChange("b", caret: 1)
        prompt.moveSelection(by: 1)

        #expect(prompt.tab(text: "b", caret: 1) == .replace(text: "bt", caret: 2))
        #expect(!prompt.isPopupOpen)
    }

    @Test
    func tabWithAClosedPopupAsksForSuggestions() {
        let prompt = prompt(["fr": ["frame"]])

        #expect(prompt.tab(text: "fr", caret: 2) == .requested)
        #expect(prompt.suggestions.map(\.insertion) == ["frame"])
    }

    @Test
    func aReplyArrivingAfterDismissalIsDropped() {
        var replies: [([Suggestion]) -> Void] = []
        let prompt = DebugConsolePromptModel { _, _, completion in replies.append(completion) }

        prompt.textDidChange("fr", caret: 2)
        prompt.dismiss()
        replies[0]([suggestion("frame", replacing: 2)])
        #expect(!prompt.isPopupOpen)

        prompt.textDidChange("fra", caret: 3)
        prompt.textDidChange("fram", caret: 4)
        replies[1]([suggestion("older", replacing: 3)])
        #expect(!prompt.isPopupOpen)
        replies[2]([suggestion("frame", replacing: 4)])
        #expect(prompt.suggestions.map(\.insertion) == ["frame"])
    }
}
