import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Language navigation entry points: Go To Definition/Usages/Implementation
/// and the language-server navigation results they publish. Back/forward
/// history and the shared editor jump live in `AppModel+NavigationHistory`.
///
/// Navigation requests are identified by an operation ID so a superseded
/// request cannot publish its results over a newer one.
@MainActor
extension AppModel {
    func goToDefinition() {
        if let document = focusedEditorDocument, let caret = editorCaret,
           caret.url.standardizedFileURL == document.url.standardizedFileURL {
            // The command asks the same plugin providers a modifier click does.
            if let pluginDefinitions = pluginDefinitionQuery(
                for: document, line: caret.line, utf16Column: caret.utf16Column
            ) {
                if supportsLanguageServerFeature(.definition) {
                    performGenericNavigation(
                        method: "textDocument/definition", kind: .definitions,
                        document: document, pluginDefinitions: pluginDefinitions)
                } else {
                    presentPluginDefinitions(
                        pluginDefinitions, documentURL: document.url.standardizedFileURL,
                        line: caret.line, utf16Column: caret.utf16Column)
                }
                return
            }
        }
        guard languageServerFeatureIsReady(
            .definition,
            unsupportedMessage: "Definition navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(method: "textDocument/definition", kind: .definitions)
    }

    func goToUsages() {
        guard languageServerFeatureIsReady(
            .references,
            unsupportedMessage: "Reference navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleResult: true
        )
    }

    func goToImplementation() {
        guard languageServerFeatureIsReady(
            .implementation,
            unsupportedMessage: "Implementation navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    /// Resolve link availability without moving the caret, recording history, or
    /// publishing a results panel. The bridge rejects stale document replies.
    /// A read-only preview passes `askPlugins: false`, so hovering a file the
    /// user only glanced at never runs plugin code.
    func requestDefinitionAvailability(
        for document: EditorDocument, line: Int, utf16Column: Int, askPlugins: Bool = true,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Every hover supersedes the previous one, even one that ends here.
        let hover = pluginDefinitionHover.begin()
        guard documentFeature.editorDocuments.contains(where: { $0 === document }) else {
            completion(.success(false)); return
        }
        let complete = askPlugins
            ? pluginSupplementedAvailability(
                ticket: hover, for: document, line: line, utf16Column: utf16Column, completion: completion)
            : completion
        guard let sessions = languageToolingSessionsIfActive, let workspaceURL,
              featureGraph.languageCapabilityPolicy.supports(
                .definition, documentURL: document.url, sessions: sessions
              ) else { complete(.success(false)); return }
        do {
            try sessions.navigate(
                method: "textDocument/definition", fileURL: document.url, text: document.text,
                position: LanguageServerPosition(line: line, utf16Column: utf16Column), rootURL: workspaceURL
            ) { result in complete(result.map { !$0.isEmpty }) }
        } catch { complete(.failure(error)) }
    }

    /// `askPlugins: false` keeps a read-only preview's click on the language
    /// server alone, as for `requestDefinitionAvailability`.
    func navigateToSymbol(line: Int, utf16Column: Int, in fileURL: URL, askPlugins: Bool = true) {
        let normalizedURL = fileURL.standardizedFileURL
        editorCaret = EditorCaret(
            url: normalizedURL,
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        let document = openDocuments.first { $0.url.standardizedFileURL == normalizedURL }
        // Plugin providers add to the language server's answer, so both run together.
        let pluginDefinitions = askPlugins ? document.flatMap {
            pluginDefinitionQuery(for: $0, line: line, utf16Column: utf16Column)
        } : nil
        let serverCanAnswer = languageProviderCatalog.provider(for: normalizedURL)?.capabilities.contains(.languageServer) == true
            && featureGraph.languageCapabilityPolicy.supports(
                .definition,
                documentURL: normalizedURL,
                sessions: languageToolingSessionsIfActive
            )
        guard serverCanAnswer else {
            if let pluginDefinitions {
                presentPluginDefinitions(pluginDefinitions, documentURL: normalizedURL, line: line, utf16Column: utf16Column)
            }
            return
        }
        performGenericNavigation(
            method: "textDocument/definition",
            kind: .definitions,
            fallbackToImplementationsIfSelf: true,
            document: document,
            pluginDefinitions: pluginDefinitions
        )
    }

    func findReferences() {
        guard languageServerFeatureIsReady(
            .references,
            unsupportedMessage: "Reference navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleResult: false
        )
    }

    func navigate(to location: LanguageNavigationLocation) {
        isImplementationChooserVisible = false
        navigate(
            to: languageNavigationCoordinator.editorLocation(
                for: location,
                virtualProviderID: location.url.isFileURL
                    ? nil
                    : languageNavigationCoordinator.state.providerID
            ),
            recordsHistory: true
        )
    }

    func dismissImplementationChooser() {
        // Selecting a target hides the chooser before virtual source loading.
        // Its later presentation callback is not a user cancellation.
        guard isImplementationChooserVisible else { return }
        closeLanguageNavigationResults()
    }

    func closeLanguageNavigationResults() {
        isReferencesVisible = false
        isImplementationChooserVisible = false
        clearLanguageNavigationProjection()
    }

    func clearLanguageNavigationProjection() {
        languageNavigationCoordinator.reset()
    }

    private func languageServerFeatureIsReady(
        _ feature: LanguageServerFeatureSet,
        unsupportedMessage: String
    ) -> Bool {
        guard focusedEditorDocument != nil else { return false }
        guard supportsLanguageServerFeature(feature) else {
            showNotification(unsupportedMessage, logReference: notificationRejection(operation: "navigation", reason: "unsupported"))
            return false
        }
        return true
    }

    private func performGenericNavigation(
        method: String,
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool = true,
        fallbackToImplementationsIfSelf: Bool = false,
        document requestedDocument: EditorDocument? = nil,
        pluginDefinitions: PluginDefinitionQuery? = nil
    ) {
        guard !languageNavigationCoordinator.state.isLoading,
              let document = requestedDocument ?? focusedEditorDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL,
              let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url) else {
            showNotification("Place the caret on a language symbol first")
            return
        }
        let operationID = languageNavigationCoordinator.begin(
            providerID: provider.id,
            kind: kind
        )
        let request = languageNavigationCoordinator.request(
            method: method,
            document: document,
            caret: caret,
            workspaceURL: workspaceURL
        )
        func present(_ values: [LanguageServerLocation]) {
            let fallback = languageNavigationCoordinator.implementationFallbackDecision(
                method: method,
                kind: kind,
                values: values,
                documentURL: document.url,
                position: request.position,
                supportsImplementation: fallbackToImplementationsIfSelf
                    && featureGraph.languageCapabilityPolicy.supports(
                        .implementation,
                        documentURL: document.url,
                        sessions: languageToolingSessionsIfActive
                    )
            )
            if fallback.shouldRequestImplementations {
                requestGenericImplementationFallback(
                    document: document,
                    caret: caret,
                    workspaceURL: workspaceURL,
                    originalValues: fallback.originalValues,
                    navigateToSingleResult: navigateToSingleResult,
                    providerID: provider.id
                )
                return
            }
            presentGenericNavigationValues(
                values,
                kind: kind,
                navigateToSingleResult: navigateToSingleResult,
                providerID: provider.id
            )
        }
        do {
            try languageToolingSessionsIfActive?.navigate(
                method: request.method,
                fileURL: request.fileURL,
                text: request.text,
                position: request.position,
                rootURL: request.rootURL
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationCoordinator.owns(operationID) else { return }
                switch result {
                case .failure(let error):
                    self.languageNavigationCoordinator.fail(
                        operationID,
                        message: error.localizedDescription
                    )
                case .success(let values):
                    guard let pluginDefinitions else { present(values); return }
                    // The server answered first; the providers finish within their own budgets.
                    Task { @MainActor [weak self] in
                        let plugin = await pluginDefinitions.task.value
                        guard let self, self.languageNavigationCoordinator.owns(operationID) else { return }
                        // Locations for an older revision of the document would point at the wrong text.
                        guard self.isCurrent(pluginDefinitions) else { present(values); return }
                        present(self.mergePluginDefinitions(
                            server: values, plugin: plugin, documentURL: document.url,
                            line: request.position.line, utf16Column: request.position.utf16Column))
                    }
                }
            }
        } catch {
            languageNavigationCoordinator.fail(
                operationID,
                message: error.localizedDescription
            )
        }
    }

    private func requestGenericImplementationFallback(
        document: EditorDocument,
        caret: EditorCaret,
        workspaceURL: URL,
        originalValues: [LanguageServerLocation],
        navigateToSingleResult: Bool,
        providerID: String
    ) {
        let operationID = languageNavigationCoordinator.begin(
            providerID: providerID,
            kind: .implementations
        )
        let request = languageNavigationCoordinator.request(
            method: "textDocument/implementation",
            document: document,
            caret: caret,
            workspaceURL: workspaceURL
        )
        do {
            try languageToolingSessionsIfActive?.navigate(
                method: request.method,
                fileURL: request.fileURL,
                text: request.text,
                position: request.position,
                rootURL: request.rootURL
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationCoordinator.owns(operationID) else { return }
                if case .success(let implementations) = result, !implementations.isEmpty {
                    self.presentGenericNavigationValues(
                        implementations,
                        kind: .implementations,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: providerID
                    )
                } else {
                    self.presentGenericNavigationValues(
                        originalValues,
                        kind: .definitions,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: providerID
                    )
                }
            }
        } catch {
            guard languageNavigationCoordinator.owns(operationID) else { return }
            presentGenericNavigationValues(
                originalValues,
                kind: .definitions,
                navigateToSingleResult: navigateToSingleResult,
                providerID: providerID
            )
        }
    }

    func presentGenericNavigationValues(
        _ values: [LanguageServerLocation],
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool,
        providerID: String?
    ) {
        languageNavigationCoordinator.handleResult(
            values,
            providerID: providerID,
            kind: kind,
            onEmpty: { [weak self] in
                guard let self else { return }
                switch kind {
                case .definitions: self.showNotification("Definition not found")
                case .references: self.showNotification("No usages found")
                case .implementations: self.showNotification("No implementations found")
                }
            },
            onResults: { [weak self] locations in
                guard let self else { return }
                if navigateToSingleResult, locations.count == 1, let location = locations.first {
                    self.isReferencesVisible = false
                    self.navigate(to: location)
                } else {
                    self.presentLanguageNavigationResults(kind)
                }
            }
        )
    }

    /// `replaysHistory` is true for Back/Forward. A history entry was already
    /// accepted when it was recorded, but the language that authorized it is
    /// not stored, and the current provider may be another language by now.
    /// Replay therefore judges the file as a source of its own language.
    func externalNavigationDecision(for url: URL, replaysHistory: Bool = false) -> ExternalNavigationDecision {
        let languageOf: (URL) -> String? = { self.languageProviderCatalog.provider(for: $0)?.id }
        let languageID = replaysHistory
            ? languageOf(url)
            : languageNavigationCoordinator.state.providerID
                ?? focusedEditorDocument.flatMap { languageOf($0.url) }
        return LanguageNavigationCoordinator.externalNavigationDecision(
            for: url,
            workspaceURL: workspaceURL,
            languageID: languageID,
            languageOf: languageOf
        )
    }

    func presentLanguageNavigationResults(_ kind: LanguageNavigationResultKind) {
        workbenchFeature.hideBottomToolWindow()
        isReferencesVisible = kind != .implementations
        isImplementationChooserVisible = kind == .implementations
    }
}
