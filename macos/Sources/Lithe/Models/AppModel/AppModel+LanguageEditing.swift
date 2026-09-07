import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Language server editing entry points: hover, completion, rename, formatting,
/// and code actions.
///
/// Each request checks the session's advertised capability first so an
/// unsupported server is a no-op rather than a failed round trip, and Spring
/// results are merged as a fallback where the language server has nothing to
/// add.
@MainActor
extension AppModel {
    func requestLanguageHover(
        line: Int,
        utf16Column: Int,
        completion: @escaping (LanguageServerHover?) -> Void
    ) {
        if let document = activeDocument,
           let hover = springFeature.hover(for: document.url, line: line) {
            completion(hover)
            return
        }
        guard let document = activeDocument,
              featureGraph.languageCapabilityPolicy.supports(.hover, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let workspaceURL else {
            completion(nil)
            return
        }
        do {
            try languageToolingSessionsIfActive?.hover(
                fileURL: document.url,
                text: document.text,
                position: featureGraph.languageEditing.position(
                    line: line,
                    utf16Column: utf16Column
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self else {
                    completion(nil)
                    return
                }
                self.featureGraph.languageEditing.handleHoverResult(
                    result,
                    completion: completion
                )
            }
        } catch {
            showNotification(error.localizedDescription)
            completion(nil)
        }
    }

    func requestLanguageCompletions(
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCompletionItem]) -> Void
    ) {
        guard let document = activeDocument else {
            completion([])
            return
        }
        let springCompletions = springFeature.completions(
            document: document,
            line: line,
            utf16Column: utf16Column
        )
        guard
              featureGraph.languageCapabilityPolicy.supports(.completion, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let workspaceURL else {
            completion(springCompletions)
            return
        }
        do {
            try languageToolingSessionsIfActive?.completions(
                fileURL: document.url,
                text: document.text,
                position: featureGraph.languageEditing.position(
                    line: line,
                    utf16Column: utf16Column
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self else {
                    completion(springCompletions)
                    return
                }
                self.featureGraph.languageEditing.handleCompletionResult(
                    result,
                    fallback: springCompletions,
                    completion: completion
                )
            }
        } catch {
            showNotification(error.localizedDescription)
            completion(springCompletions)
        }
    }

    func requestLanguageRename(
        line: Int,
        utf16Column: Int,
        newName: String
    ) {
        guard let document = activeDocument,
              featureGraph.languageCapabilityPolicy.supports(.rename, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let workspaceURL else { return }
        do {
            try languageToolingSessionsIfActive?.rename(
                fileURL: document.url,
                text: document.text,
                position: featureGraph.languageEditing.position(
                    line: line,
                    utf16Column: utf16Column
                ),
                newName: newName,
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self else { return }
                self.featureGraph.languageEditing.handleWorkspaceEditResult(
                    result,
                    apply: { [weak self] edit in _ = self?.applyLanguageWorkspaceEdit(edit) }
                )
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageFormatting() {
        guard let document = activeDocument,
              featureGraph.languageCapabilityPolicy.supports(.formatting, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let workspaceURL else { return }
        do {
            try languageToolingSessionsIfActive?.format(
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self, weak document] result in
                guard let self, let document else { return }
                self.featureGraph.languageEditing.handleFormattingResult(
                    result,
                    documentURL: document.url,
                    apply: { [weak self] edit in _ = self?.applyLanguageWorkspaceEdit(edit) }
                )
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageCodeActions(
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCodeAction]) -> Void
    ) {
        guard let document = activeDocument,
              featureGraph.languageCapabilityPolicy.supports(.codeActions, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let workspaceURL else { completion([]); return }
        let request = featureGraph.languageEditing.codeActionRequest(
            line: line,
            utf16Column: utf16Column
        )
        do {
            try languageToolingSessionsIfActive?.codeActions(
                fileURL: document.url,
                text: document.text,
                range: request.range,
                diagnostics: languageDiagnostics[document.url.standardizedFileURL] ?? [],
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let actions): completion(actions)
                case .failure(let error): self?.showNotification(error.localizedDescription); completion([])
                }
            }
        } catch { showNotification(error.localizedDescription); completion([]) }
    }

    func applyLanguageCodeAction(_ action: LanguageServerCodeAction) {
        guard let document = activeDocument, let workspaceURL else { return }
        guard action.data != nil,
              featureGraph.languageCapabilityPolicy.supports(.codeActionResolve, documentURL: document.url, sessions: languageToolingSessionsIfActive) else {
            performLanguageCodeAction(action, documentURL: document.url, rootURL: workspaceURL)
            return
        }
        do {
            try languageToolingSessionsIfActive?.resolveCodeAction(
                action,
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self else { return }
                self.featureGraph.languageEditing.handleResolvedCodeActionResult(
                    result,
                    apply: { [weak self] resolved in
                        self?.performLanguageCodeAction(
                            resolved,
                            documentURL: document.url,
                            rootURL: workspaceURL
                        )
                    }
                )
            }
        } catch { showNotification(error.localizedDescription) }
    }

    private func performLanguageCodeAction(
        _ action: LanguageServerCodeAction,
        documentURL: URL,
        rootURL: URL
    ) {
        featureGraph.languageEditing.applyCodeAction(
            action,
            applyEdit: { [weak self] edit in
                self?.applyLanguageWorkspaceEdit(edit) ?? false
            },
            executeCommand: { [weak self] command in
                guard let self,
                      let document = self.openDocuments.first(where: {
                          $0.url.standardizedFileURL == documentURL.standardizedFileURL
                      }) else { return }
                try self.languageToolingSessionsIfActive?.execute(
                    command,
                    fileURL: document.url,
                    text: document.text,
                    rootURL: rootURL
                ) { [weak self] result in
                    if case .failure(let error) = result {
                        self?.showNotification(error.localizedDescription)
                    }
                }
            }
        )
    }

    func applyLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange
    ) {
        guard let document = activeDocument, let workspaceURL else { return }
        guard item.data != nil,
              featureGraph.languageCapabilityPolicy.supports(.completionResolve, documentURL: document.url, sessions: languageToolingSessionsIfActive) else {
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
            return
        }
        do {
            try languageToolingSessionsIfActive?.resolveCompletion(
                item,
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self else { return }
                self.featureGraph.languageEditing.handleResolvedCompletionResult(
                    result,
                    fallback: { [weak self] in
                        self?.performLanguageCompletion(
                            item,
                            fallbackRange: fallbackRange,
                            documentURL: document.url
                        )
                    },
                    apply: { [weak self] resolved in
                        self?.performLanguageCompletion(
                            resolved,
                            fallbackRange: fallbackRange,
                            documentURL: document.url
                        )
                    }
                )
            }
        } catch {
            showNotification(error.localizedDescription)
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
        }
    }

    private func performLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange,
        documentURL: URL
    ) {
        applyLanguageWorkspaceEdit(
            featureGraph.languageEditing.completionWorkspaceEdit(
                item,
                fallbackRange: fallbackRange,
                documentURL: documentURL
            )
        )
    }

    @discardableResult
    private func applyLanguageWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit) -> Bool {
        guard let workspaceURL else { return false }
        return featureGraph.languageWorkspaceEdit.apply(
            edit,
            workspaceURL: workspaceURL,
            openDocuments: openDocuments,
            fileOperations: workspaceFileOperations,
            updateDocument: { [weak self] document, text in
                document.text = text
                self?.documentDidChange(document)
            }
        )
    }

    func supportsLanguageServerFeature(_ feature: LanguageServerFeatureSet) -> Bool {
        guard let document = activeDocument else { return false }
        return featureGraph.languageCapabilityPolicy.supports(
            feature,
            documentURL: document.url,
            sessions: languageToolingSessionsIfActive
        )
    }
}
