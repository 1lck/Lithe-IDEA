import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Editor navigation entry points: Go To Definition/Usages/Implementation,
/// back/forward history, and the shared editor jump used by build output,
/// diagnostics, and the debugger.
///
/// Navigation requests are identified by an operation ID so a superseded
/// request cannot publish its results over a newer one, and the caret-based
/// entry points refuse to run while the Java language server is still
/// preparing rather than reporting a spurious "not found".
@MainActor
extension AppModel {
    func goToDefinition() {
        if let document = focusedEditorDocument, let caret = editorCaret,
           caret.url.standardizedFileURL == document.url.standardizedFileURL {
            let productLocations = productNavigationLocations(
                for: document.url,
                line: caret.line,
                utf16Column: caret.utf16Column
            )
            if !productLocations.isEmpty {
                presentGenericNavigationValues(
                    productLocations,
                    kind: .definitions,
                    navigateToSingleResult: true,
                    providerID: nil
                )
                return
            }
            if languageServerIsPreparing(for: document.url) { return }
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
        if !productNavigationLocations(for: document.url, line: line, utf16Column: utf16Column).isEmpty {
            completion(.success(true)); return
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
        let productLocations = productNavigationLocations(
            for: normalizedURL,
            line: line,
            utf16Column: utf16Column
        )
        if !productLocations.isEmpty {
            presentGenericNavigationValues(
                productLocations,
                kind: .definitions,
                navigateToSingleResult: true,
                providerID: nil
            )
            return
        }
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

    func findJavaImplementations(line: Int, utf16Column: Int, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: line,
            utf16Column: utf16Column
        )
        guard languageServerFeatureIsReady(
            .implementation,
            unsupportedMessage: "Implementation navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/implementation",
            kind: .implementations,
            navigateToSingleResult: false
        )
    }

    func resolveJavaNavigation(_ marker: JavaImplementationMarker, in fileURL: URL) {
        guard !languageNavigationCoordinator.state.isLoading,
              let sessions = languageToolingSessionsIfActive,
              let provider = languageProviderCatalog.provider(for: fileURL) else { return }
        guard !isJavaLanguageServerPreparing(for: fileURL) else {
            showJavaLanguageServerPreparingNotification()
            return
        }
        let kind: LanguageNavigationResultKind = marker.direction == .down
            ? .implementations
            : .definitions
        let operationID = languageNavigationCoordinator.begin(
            providerID: provider.id,
            kind: kind
        )
        do {
            try sessions.resolveJavaNavigation(
                fileURL: fileURL,
                marker: marker.sharedMarker
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationCoordinator.owns(operationID) else { return }
                switch result {
                case .success(let locations):
                    self.presentGenericNavigationValues(
                        locations,
                        kind: kind,
                        navigateToSingleResult: true,
                        providerID: provider.id
                    )
                case .failure(let error):
                    self.languageNavigationCoordinator.fail(
                        operationID,
                        message: error.localizedDescription
                    )
                }
            }
        } catch {
            languageNavigationCoordinator.fail(
                operationID,
                message: error.localizedDescription
            )
        }
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

    var canNavigateBack: Bool { navigationHistoryFeature.canNavigateBack }
    var canNavigateForward: Bool { navigationHistoryFeature.canNavigateForward }

    func navigateBack() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateBack(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false, replaysHistory: true) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateForward() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateForward(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false, replaysHistory: true) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateToEditorLocation(
        url: URL,
        line: Int,
        utf16Column: Int,
        isReadOnly: Bool = false,
        displayPath: String? = nil,
        selectsWholeLine: Bool = false
    ) {
        navigate(
            to: EditorNavigationLocation(
                url: url,
                line: line,
                utf16Column: utf16Column,
                isReadOnly: isReadOnly,
                displayPath: displayPath,
                virtualProviderID: nil,
                selectsWholeLine: selectsWholeLine
            ),
            recordsHistory: true
        )
    }

    /// The shared jump every navigation entry point funnels through. Debug
    /// stepping opts out of history via `recordsHistory`, so this stays
    /// internal rather than file-private.
    func navigate(
        to location: EditorNavigationLocation,
        recordsHistory: Bool,
        replaysHistory: Bool = false,
        onFailure: (() -> Void)? = nil
    ) {
        // Decide before the coordinator records history or a target, so a
        // refused jump leaves both untouched.
        let external = externalNavigationDecision(for: location.url, replaysHistory: replaysHistory)
        if external == .rejected {
            showNotification("Only source files of the current language can be opened from outside the workspace", logReference: notificationRejection(operation: "codenavigation", reason: "unavailable_0"))
            onFailure?()
            return
        }
        let departure = recordsHistory ? currentEditorNavigationLocation() : nil
        if openFromPluginContentProvider(
            location, recordsHistory: recordsHistory, departure: departure, onFailure: onFailure
        ) { return }
        let providerID = location.virtualProviderID
            ?? virtualDocumentProviderIDs[location.url]
            ?? services.pluginCatalog.languageSupport(forVirtualDocumentURL: location.url)?.declaration.id
        languageNavigationCoordinator.navigate(
            to: location,
            recordsHistory: recordsHistory,
            providerID: providerID,
            sessions: languageToolingSessionsIfActive,
            recordHistory: { [weak self] destination in
                self?.navigationHistoryFeature.recordJump(from: departure, to: destination)
            },
            openFile: { [weak self] destination in
                guard let self else { return }
                // Definitions often live outside the project: Go's standard
                // library, a module cache, or stubs inside a language-server
                // package. Show them read-only instead of refusing the jump.
                let isOutsideWorkspace = external == .externalReadOnly
                self.openFile(
                    destination.url,
                    isReadOnly: destination.isReadOnly || isOutsideWorkspace,
                    displayPath: destination.displayPath,
                    allowsOutsideWorkspace: isOutsideWorkspace
                )
            },
            openVirtualDocument: { [weak self] url, text, displayPath in
                guard let self else { return }
                if let providerID {
                    self.virtualDocumentProviderIDs[url] = providerID
                }
                self.editorTabOrderFeature.repositoryDiffSelected = false
                self.documentFeature.openVirtualDocument(url, text: text, displayPath: displayPath)
            },
            setTarget: { [weak self] destination in
                guard let self else { return }
                self.editorNavigationTarget = EditorNavigationTarget(
                    url: destination.url.standardizedFileURL,
                    line: destination.line,
                    utf16Column: destination.utf16Column,
                    selectsWholeLine: destination.selectsWholeLine
                )
            },
            onFailure: onFailure
        )
    }

    private func currentEditorNavigationLocation() -> EditorNavigationLocation? {
        guard let document = focusedEditorDocument else { return nil }
        let documentURL = document.url.isFileURL ? document.url.standardizedFileURL : document.url
        let caret = editorCaret.flatMap { caret -> EditorCaret? in
            let caretURL = caret.url.isFileURL ? caret.url.standardizedFileURL : caret.url
            return caretURL == documentURL ? caret : nil
        }
        return EditorNavigationLocation(
            url: documentURL,
            line: caret?.line ?? 0,
            utf16Column: caret?.utf16Column ?? 0,
            isReadOnly: document.isReadOnly,
            displayPath: document.displayPath,
            virtualProviderID: virtualDocumentProviderIDs[documentURL]
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
        guard let document = focusedEditorDocument, !languageServerIsPreparing(for: document.url) else { return false }
        guard supportsLanguageServerFeature(feature) else {
            showNotification(unsupportedMessage, logReference: notificationRejection(operation: "navigation", reason: "unsupported"))
            return false
        }
        return true
    }

    /// Whether the language server for the file is still preparing. Tells the
    /// user so, rather than letting navigation report a spurious "not found".
    private func languageServerIsPreparing(for fileURL: URL) -> Bool {
        guard isJavaLanguageServerPreparing(for: fileURL) else { return false }
        showJavaLanguageServerPreparingNotification()
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

    /// Resolves mapper XML and Spring configuration jumps before LSP so a
    /// Mapper method does not stop on its own Java declaration.
    private func productNavigationLocations(
        for url: URL,
        line: Int,
        utf16Column: Int
    ) -> [LanguageServerLocation] {
        let mybatisLocations = mybatisFeature.navigationLocations(
            for: url,
            line: line,
            utf16Column: utf16Column
        )
        if !mybatisLocations.isEmpty { return mybatisLocations }
        return springFeature.navigationLocations(for: url, line: line)
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
