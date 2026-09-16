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
    var semanticHighlightingSessionState: String {
        guard let sessions = languageToolingSessionsIfActive else { return "" }
        return "\(sessions.semanticTokensGeneration):" + sessions.activeLanguageServerIDs.sorted().map {
            "\($0):\(sessions.languageServerFeatures[$0]?.rawValue ?? 0)"
        }.joined(separator: ";")
    }

    func requestLanguageInlayHints(for document: EditorDocument, range: LanguageServerRange,
                                  completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void) {
        guard documentFeature.editorDocuments.contains(where: { $0 === document }),
              let sessions = languageToolingSessionsIfActive else { completion(.success([])); return }
        do { try sessions.inlayHints(fileURL: document.url, range: range, completion: completion) }
        catch { completion(.failure(error)) }
    }

    func requestSemanticTokens(for document: EditorDocument, completion: @escaping (Result<LanguageServerSemanticTokens, Error>) -> Void) {
        guard let sessions = languageToolingSessionsIfActive else { completion(.success(.empty)); return }
        do { try sessions.semanticTokens(fileURL: document.url, completion: completion) }
        catch { completion(.failure(error)) }
    }

    func requestLanguageHover(
        for requestedDocument: EditorDocument? = nil,
        line: Int,
        utf16Column: Int,
        completion: @escaping (LanguageServerHover?) -> Void
    ) {
        if let document = requestedDocument ?? focusedEditorDocument,
           let hover = springFeature.hover(for: document.url, line: line) {
            completion(hover)
            return
        }
        guard let document = requestedDocument ?? focusedEditorDocument,
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
        for requestedDocument: EditorDocument? = nil,
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCompletionItem]) -> Void
    ) {
        guard let document = requestedDocument ?? focusedEditorDocument else {
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

    /// Returns the server's workspace edits without mutating native document buffers.
    /// The editor applies them only after validating its current model versions.
    func requestLanguageRenameEdits(
        for document: EditorDocument,
        line: Int,
        utf16Column: Int,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) {
        guard openDocuments.contains(where: { $0 === document }), !document.isReadOnly,
              featureGraph.languageCapabilityPolicy.supports(.rename, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let sessions = languageToolingSessionsIfActive, let workspaceURL else {
            completion(.success(LanguageServerWorkspaceEdit()))
            return
        }
        do {
            try sessions.rename(
                fileURL: document.url, text: document.text,
                position: featureGraph.languageEditing.position(line: line, utf16Column: utf16Column),
                newName: newName, rootURL: workspaceURL, completion: completion
            )
        } catch { completion(.failure(error)) }
    }

    /// Returns edits to the owning editor so formatting participates in its undo history.
    func requestLanguageFormattingEdits(
        for document: EditorDocument,
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) {
        guard openDocuments.contains(where: { $0 === document }), !document.isReadOnly,
              featureGraph.languageCapabilityPolicy.supports(.formatting, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let sessions = languageToolingSessionsIfActive, let workspaceURL else {
            completion(.success([]))
            return
        }
        do {
            try sessions.format(fileURL: document.url, text: document.text,
                                rootURL: workspaceURL, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func requestLanguageCodeActions(
        for requestedDocument: EditorDocument? = nil,
        line: Int,
        utf16Column: Int,
        range: LanguageServerRange? = nil,
        completion: @escaping ([LanguageServerCodeAction]) -> Void
    ) {
        guard let document = requestedDocument ?? focusedEditorDocument,
              openDocuments.contains(where: { $0 === document }),
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
                range: range ?? request.range,
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

    /// Resolves lazy actions without applying edits or executing a server command.
    func requestResolvedLanguageCodeAction(
        _ action: LanguageServerCodeAction,
        for document: EditorDocument,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) {
        guard openDocuments.contains(where: { $0 === document }), !document.isReadOnly else {
            completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return
        }
        guard action.data != nil,
              featureGraph.languageCapabilityPolicy.supports(.codeActionResolve, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let sessions = languageToolingSessionsIfActive, let workspaceURL else {
            completion(.success(action)); return
        }
        do {
            try sessions.resolveCodeAction(action, fileURL: document.url, text: document.text,
                                           rootURL: workspaceURL, completion: completion)
        } catch { completion(.failure(error)) }
    }

    /// Executes only the command portion after the editor has applied and synced edits.
    func executeLanguageCodeActionCommand(
        _ command: LanguageServerCommand,
        for document: EditorDocument,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard openDocuments.contains(where: { $0 === document }), !document.isReadOnly,
              let sessions = languageToolingSessionsIfActive, let workspaceURL else {
            completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return
        }
        do {
            try sessions.execute(command, fileURL: document.url, text: document.text,
                                 rootURL: workspaceURL, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func requestResolvedLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        for document: EditorDocument,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) {
        guard documentFeature.editorDocuments.contains(where: { $0 === document }),
              item.data != nil,
              featureGraph.languageCapabilityPolicy.supports(.completionResolve, documentURL: document.url, sessions: languageToolingSessionsIfActive),
              let sessions = languageToolingSessionsIfActive, let workspaceURL else {
            completion(.success(item)); return
        }
        do {
            try sessions.resolveCompletion(item, fileURL: document.url, text: document.text,
                rootURL: workspaceURL, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func supportsLanguageServerFeature(_ feature: LanguageServerFeatureSet) -> Bool {
        guard let document = focusedEditorDocument else { return false }
        return featureGraph.languageCapabilityPolicy.supports(
            feature,
            documentURL: document.url,
            sessions: languageToolingSessionsIfActive
        )
    }
}
