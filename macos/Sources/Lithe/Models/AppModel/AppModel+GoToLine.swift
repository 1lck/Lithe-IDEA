import Foundation

/// AppModel facade for the Go to Line feature: drives the `EditorChromeModel`
/// visibility flag that the dialog presenter observes, and routes the
/// submitted "line" or "line:column" input through the existing
/// `navigateToEditorLocation` pathway so jumps enter the navigation history.
extension AppModel {
    var isGoToLineVisible: Bool { editorChrome.isGoToLineVisible }

    func showGoToLine() {
        guard activeDocument != nil else { return }
        if isFindBarVisible {
            hideFindBar()
        }
        editorChrome.setGoToLineVisible(true)
    }

    func hideGoToLine() {
        editorChrome.setGoToLineVisible(false)
    }

    /// Parse "120" or "120:35" and jump; unparseable input or a missing
    /// active document is a no-op. Line and column are converged against the
    /// current document text right before jumping, without caching stale
    /// line counts, and the jump enters the navigation history so Cmd+[
    /// returns to the departure position. Line-only jumps select the whole
    /// target line; an explicitly entered column places the caret at that
    /// column instead, so the entered position is never discarded.
    func goToLine(_ text: String) {
        guard let document = activeDocument,
              let parsed = GoToLineInput.parse(text) else { return }
        let target = GoToLineInput.clamped(
            line: parsed.line,
            column: parsed.column,
            hasExplicitColumn: parsed.hasExplicitColumn,
            in: document.text
        )
        navigateToEditorLocation(
            url: document.url,
            line: target.line,
            utf16Column: target.column,
            selectsWholeLine: !target.hasExplicitColumn
        )
    }
}
