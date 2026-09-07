import Combine
import Foundation

public struct ProjectReplacementApplyResult: Sendable {
    public let changedFiles: Int
    public let failedFiles: [String]
}

/// Owns search result state and delegates matching/replacement preview semantics
/// to the shared workspace operations port.
@MainActor
public final class SearchFeatureModel: ObservableObject {
    @Published public private(set) var searchResults: [FileSearchResult] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var searchEverywhereResults = SearchEverywhereResults(
        fileMatches: [],
        contentMatches: []
    )
    @Published public private(set) var isSearchingEverywhere = false
    @Published public private(set) var projectReplacementFiles: [ProjectReplacementFile] = []
    @Published public private(set) var isLoadingProjectReplacement = false

    private let operations: any SearchOperations
    private var indexTask: Task<Void, Never>?
    private var indexTaskGeneration = 0
    private var everywhereSearchGeneration = 0
    private var replacementPreviewGeneration = 0

    public var hasActiveModuleWork: Bool {
        isSearching || isSearchingEverywhere || isLoadingProjectReplacement || indexTask != nil
    }

    public init(operations: any SearchOperations) {
        self.operations = operations
    }

    public func reset() {
        indexTaskGeneration += 1
        indexTask?.cancel()
        indexTask = nil
        searchResults = []
        isSearching = false
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
        projectReplacementFiles = []
        isLoadingProjectReplacement = false
    }

    public func warmIndex(at workspaceURL: URL, visibilityRules: SearchVisibilityRules) {
        replaceIndexTask { operations in
            operations.warmSearchIndex(at: workspaceURL, visibilityRules: visibilityRules)
        }
    }

    public func invalidateIndex(at workspaceURL: URL, visibilityRules: SearchVisibilityRules) {
        replaceIndexTask { operations in
            operations.invalidateSearchIndex(at: workspaceURL, visibilityRules: visibilityRules)
        }
    }

    public func updateIndex(
        at workspaceURL: URL,
        changedPaths: [String],
        visibilityRules: SearchVisibilityRules
    ) async {
        guard !changedPaths.isEmpty else { return }
        replaceIndexTask { operations in
            operations.updateSearchIndex(
                at: workspaceURL,
                changedPaths: changedPaths,
                visibilityRules: visibilityRules
            )
        }
        await indexTask?.value
    }

    private func replaceIndexTask(
        operation: @escaping @Sendable (any SearchOperations) -> Void
    ) {
        let previousTask = indexTask
        previousTask?.cancel()
        let operations = self.operations
        indexTaskGeneration += 1
        let generation = indexTaskGeneration
        let worker = Task.detached(priority: .utility) {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            // Search operations are synchronous ports. Run them on a GCD worker
            // so a slow indexer cannot occupy Swift's cooperative executor.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    operation(operations)
                    continuation.resume()
                }
            }
        }
        indexTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, self.indexTaskGeneration == generation else { return }
            self.indexTask = nil
        }
    }

    public func clearProjectSearch() {
        searchResults = []
        isSearching = false
    }

    public func searchProject(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearProjectSearch()
            return
        }

        isSearching = true
        let operations = self.operations
        let results = await Task.detached(priority: .userInitiated) {
            operations.search(
                at: workspaceURL,
                query: query,
                options: options,
                visibilityRules: visibilityRules
            ) ?? []
        }.value

        guard isCurrent() else {
            isSearching = false
            return
        }
        searchResults = results
        isSearching = false
    }

    public func clearSearchEverywhere() {
        everywhereSearchGeneration += 1
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
    }

    public func searchEverywhere(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        everywhereSearchGeneration += 1
        let generation = everywhereSearchGeneration
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSearchEverywhere()
            return
        }

        isSearchingEverywhere = true
        let operations = self.operations
        let indexedResults = await Task.detached(priority: .userInitiated) {
            operations.searchEverywhere(
                at: workspaceURL,
                query: query,
                options: options,
                visibilityRules: visibilityRules
            ) ?? SearchEverywhereResults()
        }.value

        guard generation == everywhereSearchGeneration, isCurrent() else {
            isSearchingEverywhere = false
            return
        }
        searchEverywhereResults = SearchEverywhereResults(
            fileMatches: indexedResults.fileMatches,
            classMatches: indexedResults.classMatches,
            symbolMatches: indexedResults.symbolMatches,
            contentMatches: indexedResults.contentMatches
        )
        isSearchingEverywhere = false
    }

    public func clearProjectReplacementPreview() {
        replacementPreviewGeneration += 1
        projectReplacementFiles = []
        isLoadingProjectReplacement = false
    }

    public func setProjectReplacementLoading(_ loading: Bool) {
        isLoadingProjectReplacement = loading
    }

    public func applyProjectReplacement(
        at workspaceURL: URL,
        selectedPaths: Set<String>,
        textOverrides: [String: String],
        recordHistory: @escaping @MainActor (String, URL) async -> Void,
        saveTextOverride: @escaping @MainActor (URL, String) throws -> Bool
    ) async -> ProjectReplacementApplyResult {
        let targets = projectReplacementFiles.filter { selectedPaths.contains($0.relativePath) }
        guard !targets.isEmpty else {
            return ProjectReplacementApplyResult(changedFiles: 0, failedFiles: [])
        }

        isLoadingProjectReplacement = true
        var changedFiles = 0
        var failedFiles: [String] = []
        for target in targets {
            let currentText = textOverrides[target.relativePath] ?? operations.readFile(
                at: workspaceURL,
                relativePath: target.relativePath
            )
            guard let currentText, let replacedText = target.replacementText else {
                failedFiles.append(target.relativePath)
                continue
            }
            guard replacedText != currentText else { continue }

            await recordHistory(currentText, target.url)
            do {
                let savedOverride = try saveTextOverride(target.url, replacedText)
                if !savedOverride && !operations.writeFile(
                    replacedText,
                    at: workspaceURL,
                    relativePath: target.relativePath
                ) {
                    throw NSError(domain: "LitheWorkspace", code: 1)
                }
                changedFiles += 1
            } catch {
                failedFiles.append(target.relativePath)
            }
        }
        isLoadingProjectReplacement = false
        return ProjectReplacementApplyResult(
            changedFiles: changedFiles,
            failedFiles: failedFiles
        )
    }

    public func previewProjectReplacement(
        at workspaceURL: URL,
        query: String,
        replacement: String,
        paths: [String],
        textOverrides: [String: String],
        options: ProjectSearchOptions = .default,
        visibilityRules: SearchVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        replacementPreviewGeneration += 1
        let generation = replacementPreviewGeneration
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearProjectReplacementPreview()
            return
        }

        isLoadingProjectReplacement = true
        let operations = self.operations
        let results = await Task.detached(priority: .userInitiated) {
            operations.previewReplacement(
                at: workspaceURL,
                query: query,
                replacement: replacement,
                options: options,
                paths: paths,
                textOverrides: textOverrides,
                visibilityRules: visibilityRules
            ) ?? []
        }.value

        guard generation == replacementPreviewGeneration, isCurrent() else {
            isLoadingProjectReplacement = false
            return
        }
        projectReplacementFiles = results
        isLoadingProjectReplacement = false
    }
}
