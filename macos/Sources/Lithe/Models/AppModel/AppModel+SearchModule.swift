import Combine
import Foundation
import LitheSearchModule

@MainActor
extension AppModel {
    var searchFeatureIfActive: SearchFeatureModel? { searchCapability?.feature }

    func activateSearchModule() async -> SearchFeatureModel? {
        await searchModuleCoordinator.activate()
    }

    func searchProject(options: ProjectSearchOptions = .default) async {
        await searchWorkflow.searchProject(options: options)
    }

    func toggleSearchEverywhere() {
        guard workspaceURL != nil, !isSearchEverywhereVisible else { return }
        openSearchEverywhere()
    }

    func openFindAction() {
        guard canPerformShortcutCommand(id: "find-action") else { return }
        openSearchEverywhere(query: "/")
    }

    private func openSearchEverywhere(query: String? = nil) {
        let wasVisible = isSearchEverywhereVisible
        let root = workspaceURL
        searchSessionFeature.everywhereGitStatus = gitTreeStatusProjection
        searchSessionFeature.beginSearchEverywhere(query: query)
        guard !wasVisible else { return }
        Task { [weak self] in
            guard let self, workspaceURL == root, isSearchEverywhereVisible else { return }
            if await activateSearchModule() == nil {
                if workspaceURL == root { dismissSearchEverywhere() }
                return
            }
            guard workspaceURL == root, isSearchEverywhereVisible else { return }
            // Git is lazy: searching must not require opening Commit first.
            await refreshGit()
            guard workspaceURL == root, isSearchEverywhereVisible else { return }
            searchSessionFeature.everywhereGitStatus = gitTreeStatusProjection
        }
    }

    func dismissSearchEverywhere() {
        guard isSearchEverywhereVisible else { return }
        searchSessionFeature.endSearchEverywhere()
        if searchSessionFeature.everywhereQuery.hasPrefix("/") {
            searchSessionFeature.everywhereQuery = ""
        }
        searchFeatureIfActive?.clearSearchEverywhere()
        documentFeature.discardPreviewDocuments(owner: .searchEverywhere)
    }

    func searchEverywhere(
        query: String,
        options: ProjectSearchOptions = .default
    ) async {
        await searchWorkflow.searchEverywhere(query: query, options: options)
    }

    func openProjectSearch() {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty { searchQuery = editorSelectedText }
        selectedSidebar = .search
        searchSidebarFocusRequest += 1
    }

    func clearProjectReplacementPreview() {
        searchFeatureIfActive?.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
    }

    func openProjectReplace(inheriting options: ProjectSearchOptions? = nil) {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty { searchQuery = editorSelectedText }
        projectReplaceQuery = searchQuery
        projectReplaceText = ""
        if let options { projectReplaceOptions = options }
        clearProjectReplacementPreview()
        isProjectReplaceVisible = true
    }

    func previewProjectReplacement(
        query: String,
        replacement: String,
        options: ProjectSearchOptions
    ) async {
        await projectReplacement.preview(query: query, replacement: replacement, options: options)
    }

    func applyProjectReplacement(query: String) async {
        await projectReplacement.apply(query: query)
    }

    func openSearchEverywhereResult(_ result: FileSearchResult) { dismissSearchEverywhere(); openSearchResult(result) }
    func performSearchEverywhereAction(_ action: LitheAction) {
        let state = workbenchUIRegistry.state(forActionID: action.id, model: self)
        guard state.isVisible && state.isEnabled else { return }
        dismissSearchEverywhere()
        action.perform()
    }

    func openSearchResult(_ result: FileSearchResult) {
        if let line = result.line {
            navigateToEditorLocation(url: result.url, line: line - 1, utf16Column: 0)
        } else {
            openFile(result.url)
        }
    }

    func openDocumentTextOverrides(rootURL: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: openDocuments.compactMap { document in
            guard let path = workspaceRelativePath(for: document.url, root: rootURL) else { return nil }
            return (path, document.text)
        })
    }
}
