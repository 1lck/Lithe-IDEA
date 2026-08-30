import Foundation

/// AppModel 的文件内查找/替换门面：读写 `EditorChromeModel` 的查找状态，
/// 并通过既有通知通路驱动当前编辑器的文本视图。
extension AppModel {
    var isFindBarVisible: Bool {
        get { editorChrome.isFindBarVisible }
        set { editorChrome.setFindBarVisible(newValue) }
    }
    var findBarQuery: String {
        get { editorChrome.findBarQuery }
        set { editorChrome.setFindBarQuery(newValue) }
    }
    var findOptions: FindInFileOptions {
        get { editorChrome.findOptions }
        set { editorChrome.setFindOptions(newValue) }
    }
    var isReplaceVisible: Bool {
        get { editorChrome.isReplaceVisible }
        set { editorChrome.setReplaceVisible(newValue) }
    }
    var findReplaceText: String {
        get { editorChrome.findReplaceText }
        set { editorChrome.setFindReplaceText(newValue) }
    }
    var findMatchCount: Int { editorChrome.findMatchCount }
    var currentFindMatchIndex: Int { editorChrome.currentFindMatchIndex }

    func showFindBar() {
        guard activeDocument != nil else { return }
        editorChrome.setFindBarVisible(true)
        editorChrome.setReplaceVisible(false)
    }

    /// Cmd+R：查找栏未显示时带替换行打开，否则在查找/替换之间切换。
    func showReplaceBar() {
        guard activeDocument != nil else { return }
        if isFindBarVisible {
            editorChrome.setReplaceVisible(!editorChrome.isReplaceVisible)
        } else {
            editorChrome.setFindBarVisible(true)
            editorChrome.setReplaceVisible(true)
        }
    }

    func hideFindBar() {
        editorChrome.resetFindBar()
        NotificationCenter.default.post(name: .litheFindDismiss, object: nil)
    }

    func toggleFindBar() {
        if isFindBarVisible {
            hideFindBar()
        } else {
            showFindBar()
        }
    }

    func setFindBarQuery(_ query: String) {
        editorChrome.setFindBarQuery(query)
        postFindQueryChangedNotification()
    }

    func setFindOptions(_ options: FindInFileOptions) {
        editorChrome.setFindOptions(options)
        postFindQueryChangedNotification()
    }

    func setFindReplaceText(_ text: String) {
        editorChrome.setFindReplaceText(text)
    }

    private func postFindQueryChangedNotification() {
        let options = editorChrome.findOptions
        NotificationCenter.default.post(
            name: .litheFindQueryChanged,
            object: nil,
            userInfo: [
                FindNotificationKeys.query: editorChrome.findBarQuery,
                FindNotificationKeys.matchCase: options.matchCase,
                FindNotificationKeys.wholeWords: options.wholeWords,
                FindNotificationKeys.regularExpression: options.regularExpression
            ]
        )
    }

    func navigateFind(offset: Int) {
        NotificationCenter.default.post(
            name: .litheFindNavigate,
            object: nil,
            userInfo: [FindNotificationKeys.direction: offset]
        )
    }

    func replaceNextFindMatch() {
        NotificationCenter.default.post(
            name: .litheFindReplaceNext,
            object: nil,
            userInfo: [FindNotificationKeys.replacement: editorChrome.findReplaceText]
        )
    }

    func replaceAllFindMatches() {
        NotificationCenter.default.post(
            name: .litheFindReplaceAll,
            object: nil,
            userInfo: [FindNotificationKeys.replacement: editorChrome.findReplaceText]
        )
    }

    func updateFindState(currentIndex: Int, count: Int) {
        editorChrome.updateFindState(currentIndex: currentIndex, count: count)
    }
}
