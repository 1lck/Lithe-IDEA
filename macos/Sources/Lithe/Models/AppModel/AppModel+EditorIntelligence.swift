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
        announceMavenResolutionProblemsIfChanged()
    }

    /// Maven problems JDT LS currently reports for the open workspace.
    var mavenResolutionProblems: [EditorDiagnostic] {
        MavenResolutionProblems.problems(
            workspaceURL: workspaceURL,
            diagnosticsByURL: editorDiagnosticsStore.diagnosticsByURL
        )
    }

    /// Notifies once per distinct Maven problem set, even when the Maven tool
    /// window is closed. A failed import otherwise looks like a successful one.
    private func announceMavenResolutionProblemsIfChanged() {
        let problems = mavenResolutionProblems
        let signature = MavenResolutionProblems.signature(problems)
        // An empty set keeps the last signature: the same failure reappearing
        // after a rebuild is visible in the Maven tool window already.
        guard !signature.isEmpty, signature != announcedMavenResolutionProblems,
              let first = problems.first else { return }
        announcedMavenResolutionProblems = signature
        showNotification(String(
            format: String(localized: "Maven could not resolve this project (%lld problems): %@"),
            problems.count,
            first.message
        ))
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
