import Foundation
import LitheSearchModule
import LitheLocalHistoryModule

/// Coordinates project replacement while delegating document and history policy.
@MainActor
final class ProjectReplacementCoordinator {
    private let session: SearchSessionFeatureModel
    private let activate: () async -> SearchFeatureModel?
    private let workspace: () -> URL?
    private let paths: (URL) -> [String]
    private let overrides: (URL) -> [String: String]
    private let visibilityRules: () -> SearchVisibilityRules
    private let recordHistory: (String, URL) async -> Void
    private let saveOverride: (URL, String) throws -> Bool
    private let refreshWorkspace: () async -> Void
    private let markIdle: () -> Void
    private let notify: (String) -> Void

    init(
        session: SearchSessionFeatureModel,
        activate: @escaping () async -> SearchFeatureModel?,
        workspace: @escaping () -> URL?,
        paths: @escaping (URL) -> [String],
        overrides: @escaping (URL) -> [String: String],
        visibilityRules: @escaping () -> SearchVisibilityRules,
        recordHistory: @escaping (String, URL) async -> Void,
        saveOverride: @escaping (URL, String) throws -> Bool,
        refreshWorkspace: @escaping () async -> Void,
        markIdle: @escaping () -> Void,
        notify: @escaping (String) -> Void
    ) {
        self.session = session
        self.activate = activate
        self.workspace = workspace
        self.paths = paths
        self.overrides = overrides
        self.visibilityRules = visibilityRules
        self.recordHistory = recordHistory
        self.saveOverride = saveOverride
        self.refreshWorkspace = refreshWorkspace
        self.markIdle = markIdle
        self.notify = notify
    }

    func preview(query: String, replacement: String, options: ProjectSearchOptions) async {
        guard let root = workspace(), let feature = await activate() else { return }
        await feature.previewProjectReplacement(
            at: root, query: query, replacement: replacement,
            paths: paths(root), textOverrides: overrides(root), options: options,
            visibilityRules: visibilityRules(),
            isCurrent: { [weak session, workspace] in
                session?.isProjectReplaceVisible == true && workspace() == root
            }
        )
        guard session.isProjectReplaceVisible else { return }
        session.selectedReplacementPaths = Set(feature.projectReplacementFiles.map(\.relativePath))
    }

    func apply(query: String) async {
        guard let root = workspace(),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let feature = await activate() else { return }
        let result = await feature.applyProjectReplacement(
            at: root,
            selectedPaths: session.selectedReplacementPaths,
            textOverrides: overrides(root),
            recordHistory: recordHistory,
            saveTextOverride: saveOverride
        )
        markIdle()
        session.isProjectReplaceVisible = false
        feature.clearProjectReplacementPreview()
        session.selectedReplacementPaths = []
        await refreshWorkspace()
        if !result.failedFiles.isEmpty {
            notify("Could not replace in \(result.failedFiles.count) file(s)")
        } else if result.changedFiles > 0 {
            notify("Replaced text in \(result.changedFiles) file(s)")
        }
    }
}
