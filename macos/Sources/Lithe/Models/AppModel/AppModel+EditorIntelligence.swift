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
}
