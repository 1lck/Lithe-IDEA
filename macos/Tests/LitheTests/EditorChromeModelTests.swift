import Combine
import Foundation
import Testing
@testable import Lithe

@MainActor
struct EditorChromeModelTests {
    @Test
    func unchangedCaretAndSelectionDoNotPublish() {
        let chrome = EditorChromeModel()
        let caret = EditorCaret(
            url: URL(fileURLWithPath: "/workspace/App.java"),
            line: 3,
            utf16Column: 8
        )
        chrome.update(caret: caret)
        chrome.update(selectedText: "name")

        var publishCount = 0
        let observation = chrome.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        chrome.update(caret: caret)
        chrome.update(selectedText: "name")
        #expect(publishCount == 0)

        chrome.update(caret: EditorCaret(url: caret.url, line: 4, utf16Column: 0))
        #expect(publishCount == 1)
        chrome.update(selectedText: "")
        #expect(publishCount == 2)
    }

    @Test
    func resetClearsCaretAndSelectionOnceEach() {
        let chrome = EditorChromeModel()
        chrome.update(
            caret: EditorCaret(url: URL(fileURLWithPath: "/workspace/App.java"), line: 0, utf16Column: 0)
        )
        chrome.update(selectedText: "foo")

        var publishCount = 0
        let observation = chrome.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        chrome.reset()
        #expect(chrome.caret == nil)
        #expect(chrome.selectedText.isEmpty)
        #expect(publishCount == 2)

        chrome.reset()
        #expect(publishCount == 2)
    }

    @Test
    func findBarUpdatesDoNotPublishUnchangedValues() {
        let chrome = EditorChromeModel()
        chrome.setFindBarVisible(true)
        chrome.setFindBarQuery("foo")
        chrome.updateFindState(currentIndex: 1, count: 3)

        var publishCount = 0
        let observation = chrome.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        chrome.setFindBarVisible(true)
        chrome.setFindBarQuery("foo")
        chrome.updateFindState(currentIndex: 1, count: 3)
        #expect(publishCount == 0)

        chrome.setFindBarQuery("bar")
        #expect(publishCount == 1)
        chrome.updateFindState(currentIndex: 0, count: 2)
        #expect(publishCount == 2)
    }

    @Test
    func goToLineDialogAndFindBarAreMutuallyExclusive() {
        // The find bar and the go-to-line dialog are mutually exclusive:
        // opening either dismisses the other.
        let chrome = EditorChromeModel()
        chrome.setFindBarVisible(true)
        chrome.setGoToLineVisible(true)
        #expect(chrome.isGoToLineVisible)
        #expect(!chrome.isFindBarVisible)

        chrome.setFindBarVisible(true)
        #expect(chrome.isFindBarVisible)
        #expect(!chrome.isGoToLineVisible)

        chrome.setGoToLineVisible(false)
        #expect(!chrome.isGoToLineVisible)
        #expect(chrome.isFindBarVisible)
    }

    @Test
    func resetClosesGoToLineBar() {
        let chrome = EditorChromeModel()
        chrome.setGoToLineVisible(true)

        chrome.reset()

        #expect(!chrome.isGoToLineVisible)
    }
}
