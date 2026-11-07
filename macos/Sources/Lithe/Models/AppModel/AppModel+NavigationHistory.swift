import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Back/forward navigation history and the shared editor jump used by build
/// output, diagnostics, and the debugger. Split from `AppModel+CodeNavigation`
/// so each extension stays within one domain.
@MainActor
extension AppModel {
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
}
