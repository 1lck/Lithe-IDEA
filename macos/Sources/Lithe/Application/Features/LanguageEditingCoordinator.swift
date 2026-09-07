import Foundation
import LitheCoreContracts

/// Owns language-editing value preparation and result handling shared by
/// editor actions.
///
/// The coordinator holds the user-facing failure channel rather than taking it
/// per call, so every language-server round trip reports errors the same way.
@MainActor
final class LanguageEditingCoordinator {
    private let notify: @MainActor (String) -> Void

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    struct CodeActionRequest {
        let position: LanguageServerPosition
        let range: LanguageServerRange
    }

    func position(line: Int, utf16Column: Int) -> LanguageServerPosition {
        LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column))
    }

    func mergeCompletions(
        _ local: [LanguageServerCompletionItem],
        with languageServer: [LanguageServerCompletionItem]
    ) -> [LanguageServerCompletionItem] {
        var seen = Set<String>()
        return (local + languageServer).filter { seen.insert($0.label).inserted }
    }

    func completionWorkspaceEdit(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange,
        documentURL: URL
    ) -> LanguageServerWorkspaceEdit {
        let sourceEdit = item.textEdit ?? LanguageServerTextEdit(
            range: fallbackRange,
            newText: item.insertText
        )
        let primaryEdit = LanguageServerTextEdit(
            range: sourceEdit.range,
            newText: LanguageServerSnippet.plainText(sourceEdit.newText)
        )
        return LanguageServerWorkspaceEdit(
            changes: [documentURL.standardizedFileURL: [primaryEdit] + item.additionalTextEdits]
        )
    }

    func codeActionRange(
        line: Int,
        utf16Column: Int
    ) -> LanguageServerRange {
        let position = position(line: line, utf16Column: utf16Column)
        return LanguageServerRange(start: position, end: position)
    }

    func codeActionRequest(
        line: Int,
        utf16Column: Int
    ) -> CodeActionRequest {
        let range = codeActionRange(line: line, utf16Column: utf16Column)
        return CodeActionRequest(position: range.start, range: range)
    }

    func formattingWorkspaceEdit(
        documentURL: URL,
        edits: [LanguageServerTextEdit]
    ) -> LanguageServerWorkspaceEdit {
        LanguageServerWorkspaceEdit(
            changes: [documentURL.standardizedFileURL: edits]
        )
    }

    func applyCodeAction(
        _ action: LanguageServerCodeAction,
        applyEdit: (LanguageServerWorkspaceEdit) -> Bool,
        executeCommand: (LanguageServerCommand) throws -> Void
    ) {
        if let edit = action.edit, !applyEdit(edit) { return }
        guard let command = action.command else {
            if action.edit == nil {
                notify("This language action has no executable change.")
            }
            return
        }
        do {
            try executeCommand(command)
        } catch {
            notify(error.localizedDescription)
        }
    }

    func handleWorkspaceEditResult(
        _ result: Result<LanguageServerWorkspaceEdit, Error>,
        apply: (LanguageServerWorkspaceEdit) -> Void
    ) {
        switch result {
        case .success(let edit):
            apply(edit)
        case .failure(let error):
            notify(error.localizedDescription)
        }
    }

    func handleFormattingResult(
        _ result: Result<[LanguageServerTextEdit], Error>,
        documentURL: URL,
        apply: (LanguageServerWorkspaceEdit) -> Void
    ) {
        switch result {
        case .success(let edits):
            apply(formattingWorkspaceEdit(documentURL: documentURL, edits: edits))
        case .failure(let error):
            notify(error.localizedDescription)
        }
    }

    func handleHoverResult(
        _ result: Result<LanguageServerHover?, Error>,
        completion: (LanguageServerHover?) -> Void
    ) {
        switch result {
        case .success(let hover):
            completion(hover)
        case .failure(let error):
            notify(error.localizedDescription)
            completion(nil)
        }
    }

    func handleCompletionResult(
        _ result: Result<[LanguageServerCompletionItem], Error>,
        fallback: [LanguageServerCompletionItem],
        completion: ([LanguageServerCompletionItem]) -> Void
    ) {
        switch result {
        case .success(let values):
            completion(mergeCompletions(fallback, with: values))
        case .failure(let error):
            notify(error.localizedDescription)
            completion(fallback)
        }
    }

    func handleResolvedCodeActionResult(
        _ result: Result<LanguageServerCodeAction, Error>,
        apply: (LanguageServerCodeAction) -> Void
    ) {
        switch result {
        case .success(let action):
            apply(action)
        case .failure(let error):
            notify(error.localizedDescription)
        }
    }

    func handleResolvedCompletionResult(
        _ result: Result<LanguageServerCompletionItem, Error>,
        fallback: @escaping () -> Void,
        apply: (LanguageServerCompletionItem) -> Void
    ) {
        switch result {
        case .success(let item):
            apply(item)
        case .failure(let error):
            notify(error.localizedDescription)
            fallback()
        }
    }
}
