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
        if let document = activeDocument, let caret = editorCaret {
            let springLocations = springFeature.navigationLocations(
                for: document.url,
                line: caret.line
            )
            if !springLocations.isEmpty {
                presentGenericNavigationValues(
                    springLocations,
                    kind: .definitions,
                    navigateToSingleResult: true,
                    providerID: nil
                )
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

    func navigateToSymbol(line: Int, utf16Column: Int, in fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        guard languageProviderCatalog.provider(for: normalizedURL)?.capabilities.contains(.languageServer) == true
        else { return }
        editorCaret = EditorCaret(
            url: normalizedURL,
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        if featureGraph.languageCapabilityPolicy.supports(
            .definition,
            documentURL: normalizedURL,
            sessions: languageToolingSessionsIfActive
        ) {
            performGenericNavigation(
                method: "textDocument/definition",
                kind: .definitions,
                fallbackToImplementationsIfSelf: true
            )
        }
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
        navigate(to: location, recordsHistory: false) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateForward() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateForward(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false) { [weak self] in
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
        onFailure: (() -> Void)? = nil
    ) {
        let departure = recordsHistory ? currentEditorNavigationLocation() : nil
        let providerID = location.virtualProviderID
            ?? virtualDocumentProviderIDs[location.url]
            ?? languageNavigationCoordinator.state.providerID
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
                self.openFile(
                    destination.url,
                    isReadOnly: destination.isReadOnly,
                    displayPath: destination.displayPath
                )
            },
            openVirtualDocument: { [weak self] url, text, displayPath in
                guard let self else { return }
                if let providerID {
                    self.virtualDocumentProviderIDs[url] = providerID
                }
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
        guard let document = activeDocument else { return nil }
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
        guard let document = activeDocument else { return false }
        if isJavaLanguageServerPreparing(for: document.url) {
            showJavaLanguageServerPreparingNotification()
            return false
        }
        guard supportsLanguageServerFeature(feature) else {
            showNotification(unsupportedMessage)
            return false
        }
        return true
    }

    private func performGenericNavigation(
        method: String,
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool = true,
        fallbackToImplementationsIfSelf: Bool = false
    ) {
        guard !languageNavigationCoordinator.state.isLoading,
              let document = activeDocument,
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
                    let fallback = self.languageNavigationCoordinator.implementationFallbackDecision(
                        method: method,
                        kind: kind,
                        values: values,
                        documentURL: document.url,
                        supportsImplementation: fallbackToImplementationsIfSelf
                            && self.featureGraph.languageCapabilityPolicy.supports(
                                .implementation,
                                documentURL: document.url,
                                sessions: self.languageToolingSessionsIfActive
                            )
                    )
                    if fallback.shouldRequestImplementations {
                        self.requestGenericImplementationFallback(
                            document: document,
                            caret: caret,
                            workspaceURL: workspaceURL,
                            originalValues: fallback.originalValues,
                            navigateToSingleResult: navigateToSingleResult,
                            providerID: provider.id
                        )
                        return
                    }
                    self.presentGenericNavigationValues(
                        values,
                        kind: kind,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: provider.id
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

    private func presentGenericNavigationValues(
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
                    self.navigate(to: location)
                } else {
                    self.presentLanguageNavigationResults(kind)
                }
            }
        )
    }

    func presentLanguageNavigationResults(_ kind: LanguageNavigationResultKind) {
        workbenchFeature.hideAllToolWindows()
        isReferencesVisible = kind != .implementations
        isImplementationChooserVisible = kind == .implementations
    }
}
