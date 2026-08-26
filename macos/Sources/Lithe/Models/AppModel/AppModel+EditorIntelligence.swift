import Foundation

struct LanguageSessionChromeSignature: Equatable {
    var features: [String: LanguageServerFeatureSet]
    var states: [String: LanguageServerSessionState]
    var infos: [String: LanguageServerInfo]
}

extension AppModel {
    func handleLanguageSessionChange() {
        refreshEditorDiagnosticsStore()
        let signature = LanguageSessionChromeSignature(
            features: languageToolingSessionsIfActive?.languageServerFeatures ?? [:],
            states: languageToolingSessionsIfActive?.languageServerStates ?? [:],
            infos: languageToolingSessionsIfActive?.languageServerInfos ?? [:]
        )
        guard signature != languageSessionChromeSignature else { return }
        languageSessionChromeSignature = signature
        scheduleObjectWillChangeRelay()
    }

    func refreshEditorDiagnosticsStore() {
        editorDiagnosticsStore.replace(
            EditorDiagnostic.fromLanguageServerDiagnostics(languageDiagnostics)
        )
    }

    func refreshCodeVision(for fileURL: URL) async {
        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.pathExtension.lowercased() == "java",
              let document = openDocuments.first(where: { $0.url.standardizedFileURL == normalizedURL }),
              !document.isReadOnly,
              let workspaceRoot = workspaceURL else { return }
        await javaFeature.refreshCodeVision(
            for: document,
            projectFiles: projectFiles,
            workspaceRoot: workspaceRoot
        )
    }

    func refreshJavaInlayHints(for document: EditorDocument) {
        javaFeature.refreshInlayHints(
            for: document,
            projectFiles: projectFiles,
            workspaceRoot: workspaceURL
        )
    }

    func showBlame(for fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        blameVisibleURL = blameVisibleURL == normalizedURL ? nil : normalizedURL
    }

    func hideBlame() {
        blameVisibleURL = nil
    }

    func findUsages(for hint: JavaCodeVisionHint, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: hint.line,
            utf16Column: hint.utf16Column
        )
        findReferences()
    }
}
