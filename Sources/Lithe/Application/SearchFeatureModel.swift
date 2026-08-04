import Combine
import Foundation

struct ProjectReplacementApplyResult: Sendable {
    let changedFiles: Int
    let failedFiles: [String]
}

/// Owns search result state and delegates matching/replacement preview semantics
/// to the shared workspace operations port.
@MainActor
final class SearchFeatureModel: ObservableObject {
    @Published private(set) var searchResults: [FileSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchEverywhereResults = SearchEverywhereResults(
        fileMatches: [],
        contentMatches: []
    )
    @Published private(set) var isSearchingEverywhere = false
    @Published private(set) var projectReplacementFiles: [ProjectReplacementFile] = []
    @Published private(set) var isLoadingProjectReplacement = false

    private let operations: any WorkspaceOperations

    init(operations: any WorkspaceOperations) {
        self.operations = operations
    }

    func reset() {
        searchResults = []
        isSearching = false
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
        projectReplacementFiles = []
        isLoadingProjectReplacement = false
    }

    func clearProjectSearch() {
        searchResults = []
        isSearching = false
    }

    func searchProject(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules,
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

    func clearSearchEverywhere() {
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
    }

    func searchEverywhere(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules,
        actionMatches: [LitheAction],
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
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

        guard isCurrent() else {
            isSearchingEverywhere = false
            return
        }
        searchEverywhereResults = SearchEverywhereResults(
            fileMatches: indexedResults.fileMatches,
            classMatches: indexedResults.classMatches,
            symbolMatches: indexedResults.symbolMatches,
            contentMatches: indexedResults.contentMatches,
            actionMatches: actionMatches
        )
        isSearchingEverywhere = false
    }

    func clearProjectReplacementPreview() {
        projectReplacementFiles = []
        isLoadingProjectReplacement = false
    }

    func setProjectReplacementLoading(_ loading: Bool) {
        isLoadingProjectReplacement = loading
    }

    func applyProjectReplacement(
        at workspaceURL: URL,
        selectedPaths: Set<String>,
        documents: [EditorDocument],
        recordHistory: @escaping @MainActor (String, URL) async -> Void,
        saveDocument: @escaping @MainActor (EditorDocument) throws -> Void
    ) async -> ProjectReplacementApplyResult {
        let targets = projectReplacementFiles.filter { selectedPaths.contains($0.relativePath) }
        guard !targets.isEmpty else {
            return ProjectReplacementApplyResult(changedFiles: 0, failedFiles: [])
        }

        isLoadingProjectReplacement = true
        var changedFiles = 0
        var failedFiles: [String] = []
        for target in targets {
            let document = documents.first { $0.url.standardizedFileURL == target.url.standardizedFileURL }
            let currentText = document?.text ?? operations.readFile(
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
                if let document {
                    document.text = replacedText
                    try saveDocument(document)
                } else if !operations.writeFile(
                    replacedText,
                    at: workspaceURL,
                    relativePath: target.relativePath
                ) {
                    throw NSError(domain: "LitheWorkspace", code: 1)
                }
                changedFiles += 1
            } catch {
                if let document {
                    document.text = currentText
                }
                failedFiles.append(target.relativePath)
            }
        }
        isLoadingProjectReplacement = false
        return ProjectReplacementApplyResult(
            changedFiles: changedFiles,
            failedFiles: failedFiles
        )
    }

    func previewProjectReplacement(
        at workspaceURL: URL,
        query: String,
        replacement: String,
        paths: [String],
        textOverrides: [String: String],
        options: ProjectSearchOptions = .default,
        visibilityRules: FileVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
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

        guard isCurrent() else {
            isLoadingProjectReplacement = false
            return
        }
        projectReplacementFiles = results
        isLoadingProjectReplacement = false
    }
}
