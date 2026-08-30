import Combine
import Foundation

/// Caret, selection, and Find in File chrome. These values change on arrow
/// keys and query keystrokes, so they live off `AppModel` and must not
/// republish the workbench tree.
@MainActor
final class EditorChromeModel: ObservableObject {
    @Published private(set) var caret: EditorCaret?
    @Published private(set) var selectedText = ""
    @Published private(set) var isFindBarVisible = false
    @Published private(set) var isGoToLineVisible = false
    @Published private(set) var findBarQuery = ""
    private(set) var findMatchCount = 0
    private(set) var currentFindMatchIndex = 0

    func update(caret: EditorCaret?) {
        guard self.caret != caret else { return }
        self.caret = caret
    }

    func update(selectedText: String) {
        guard self.selectedText != selectedText else { return }
        self.selectedText = selectedText
    }

    func setFindBarVisible(_ isVisible: Bool) {
        guard isFindBarVisible != isVisible else { return }
        isFindBarVisible = isVisible
        // 查找栏与跳转条互斥，任一打开都会收起另一个
        if isVisible, isGoToLineVisible {
            setGoToLineVisible(false)
        }
    }

    func setGoToLineVisible(_ isVisible: Bool) {
        guard isGoToLineVisible != isVisible else { return }
        isGoToLineVisible = isVisible
        if isVisible, isFindBarVisible {
            setFindBarVisible(false)
        }
    }

    func setFindBarQuery(_ query: String) {
        guard findBarQuery != query else { return }
        findBarQuery = query
    }

    func updateFindState(currentIndex: Int, count: Int) {
        guard currentFindMatchIndex != currentIndex || findMatchCount != count else { return }
        objectWillChange.send()
        currentFindMatchIndex = currentIndex
        findMatchCount = count
    }

    func resetFindBar() {
        setFindBarVisible(false)
        setFindBarQuery("")
        updateFindState(currentIndex: 0, count: 0)
    }

    func reset() {
        update(caret: nil)
        update(selectedText: "")
        resetFindBar()
        setGoToLineVisible(false)
    }
}
