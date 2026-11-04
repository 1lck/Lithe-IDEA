import Foundation
import LitheModuleAPI

struct LanguageSessionChromeSignature: Equatable {
    var features: [String: LanguageServerFeatureSet]
    var states: [String: LanguageServerSessionState]
    var infos: [String: LanguageServerInfo]
}

/// Menu availability uses the discovered workspace roots; the eventual blame
/// request still resolves the file's actual repository in Core.
func gitBlameCanAnnotate(_ fileURL: URL, repositoryRoots: [URL], isUntracked: Bool) -> Bool {
    guard fileURL.isFileURL, !isUntracked else { return false }
    let url = fileURL.standardizedFileURL
    return repositoryRoots.contains { root in
        let root = root.standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return url != root && url.path.hasPrefix(prefix)
    }
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
        // Settings language pages observe `AppModel` directly for server status.
        scheduleObjectWillChangeRelay(affectsSettings: false)
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
            format: L10n.string("Maven could not resolve this project (%lld problems): %@"),
            problems.count,
            first.message
        ), logReference: notificationRejection(operation: "project_import", reason: "resolution_failed"))
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

    func canShowBlame(for fileURL: URL) -> Bool {
        let roots = (gitFeatureIfActive?.availableRepositoryRoots ?? []) + [gitRepositoryRoot].compactMap { $0 }
        return gitBlameCanAnnotate(fileURL, repositoryRoots: roots,
                                   isUntracked: gitChange(for: fileURL.standardizedFileURL)?.isUntracked == true)
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
