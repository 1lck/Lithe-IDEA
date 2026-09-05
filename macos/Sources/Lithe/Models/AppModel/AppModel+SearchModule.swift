import Combine
import Foundation
import LitheSearchModule

@MainActor
extension AppModel {
    var searchFeatureIfActive: SearchFeatureModel? { searchCapability?.feature }

    func activateSearchModule() async -> SearchFeatureModel? {
        if let feature = searchFeatureIfActive { return feature }
        do {
            let value = try await services.moduleRuntime.activateCapability(.searchWorkspace)
            guard let capability = value as? LitheSearchModule.SearchModuleCapability else { return nil }
            cacheModuleCapability(capability, id: .searchWorkspace, moduleID: .search)
            observeModuleFeature(.search, observation: capability.feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            if let workspaceURL {
                capability.feature.warmIndex(
                    at: workspaceURL,
                    visibilityRules: settings.fileVisibilityRules.searchRules
                )
            }
            return capability.feature
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }

    func searchProject(options: ProjectSearchOptions = .default) async {
        guard let workspaceURL, let searchFeature = await activateSearchModule() else { return }
        let query = searchQuery
        await searchFeature.searchProject(
            at: workspaceURL, query: query, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            isCurrent: { [weak self] in self?.workspaceURL == workspaceURL && self?.searchQuery == query }
        )
        try? services.moduleRuntime.markIdle(.search)
    }

    func toggleSearchEverywhere() {
        guard workspaceURL != nil, !isSearchEverywhereVisible else { return }
        isSearchEverywhereVisible = true
        Task { _ = await activateSearchModule() }
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
        let signpost = LitheSignpost.begin("search.everywhere")
        defer { LitheSignpost.end("search.everywhere", signpost) }
        guard let searchFeature = await activateSearchModule() else { return }
        guard let workspaceURL else { searchFeature.clearSearchEverywhere(); return }
        await searchFeature.searchEverywhere(
            at: workspaceURL, query: query, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            isCurrent: { [weak self] in
                self?.workspaceURL == workspaceURL && self?.isSearchEverywhereVisible == true
            }
        )
        try? services.moduleRuntime.markIdle(.search)
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
        guard let rootURL = workspaceURL, let searchFeature = await activateSearchModule() else { return }
        let overrides = openDocumentTextOverrides(rootURL: rootURL)
        await searchFeature.previewProjectReplacement(
            at: rootURL, query: query, replacement: replacement,
            paths: projectFiles.compactMap { workspaceRelativePath(for: $0, root: rootURL) },
            textOverrides: overrides, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            isCurrent: { [weak self] in self?.workspaceURL == rootURL && self?.isProjectReplaceVisible == true }
        )
        try? services.moduleRuntime.markIdle(.search)
        guard isProjectReplaceVisible else { return }
        selectedProjectReplacementPaths = Set(projectReplacementFiles.map(\.relativePath))
    }

    func applyProjectReplacement() async {
        guard let rootURL = workspaceURL,
              !projectReplaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let searchFeature = await activateSearchModule() else { return }
        let result = await searchFeature.applyProjectReplacement(
            at: rootURL, selectedPaths: selectedProjectReplacementPaths,
            textOverrides: openDocumentTextOverrides(rootURL: rootURL),
            recordHistory: { [weak self] text, fileURL in
                guard let feature = await self?.activateHistoryModule() else { return }
                await feature.recordHistorySnapshot(text: text, for: fileURL, reason: .beforeBatchReplace)
            },
            saveTextOverride: { [weak self] url, text in
                guard let self,
                      let document = self.openDocuments.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return false }
                let previousText = document.text
                document.text = text
                do { try self.saveDocument(document); return true }
                catch { document.text = previousText; throw error }
            }
        )
        try? services.moduleRuntime.markIdle(.search)
        isProjectReplaceVisible = false
        searchFeature.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
        await refreshWorkspace()
        if !result.failedFiles.isEmpty { showNotification("Could not replace in \(result.failedFiles.count) file(s)") }
        else if result.changedFiles > 0 { showNotification("Replaced text in \(result.changedFiles) file(s)") }
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

    private func openDocumentTextOverrides(rootURL: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: openDocuments.compactMap { document in
            guard let path = workspaceRelativePath(for: document.url, root: rootURL) else { return nil }
            return (path, document.text)
        })
    }
}
