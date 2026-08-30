import Foundation

/// AppModel 的按行号跳转门面：驱动 `EditorChromeModel` 的跳转条显隐，
/// 并把状态栏、菜单和快捷键入口提交的“行:列”输入经现有导航通路
/// `navigateToEditorLocation` 跳转到目标行，进入既有导航历史。
extension AppModel {
    var isGoToLineVisible: Bool { editorChrome.isGoToLineVisible }

    func showGoToLineBar() {
        guard activeDocument != nil else { return }
        if isFindBarVisible {
            hideFindBar()
        }
        editorChrome.setGoToLineVisible(true)
    }

    func hideGoToLineBar() {
        editorChrome.setGoToLineVisible(false)
    }

    /// 解析“120”或“120:35”输入并跳转，解析失败或无活动文档时为无操作。
    /// 跳转前用当前文档文本重新收敛行列，不缓存打开输入框时的行数；
    /// 跳转进入导航历史，Cmd+[ 可以回到跳转前的位置。
    func goToLine(_ text: String) {
        guard let document = activeDocument,
              let parsed = GoToLineInput.parse(text) else { return }
        let target = GoToLineInput.clamped(line: parsed.line, column: parsed.column, in: document.text)
        navigateToEditorLocation(
            url: document.url,
            line: target.line,
            utf16Column: target.column,
            selectsWholeLine: true
        )
    }
}
