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
        isSearchEverywhereVisible = true
        Task { [weak self] in
            guard let self else { return }
            if await activateSearchModule() == nil {
                isSearchEverywhereVisible = false
            }
        }
    }

    func dismissSearchEverywhere() {
        isSearchEverywhereVisible = false
        searchEverywhereQuery = ""
        searchFeatureIfActive?.clearSearchEverywhere()
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
    func performSearchEverywhereAction(_ action: LitheAction) { dismissSearchEverywhere(); action.perform() }

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
