import Foundation

public struct SearchVisibilityRules: Hashable, Sendable {
    public let hiddenDirectoryNames: [String]
    public let hiddenFilePatterns: [String]

    public init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String]) {
        self.hiddenDirectoryNames = hiddenDirectoryNames
        self.hiddenFilePatterns = hiddenFilePatterns
    }
}

public protocol SearchOperations: Sendable {
    func warmSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules)
    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: SearchVisibilityRules)
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules)
    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules
    ) -> [FileSearchResult]?

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>
    ) -> SearchEverywhereResults?

    /// Receives bounded replacement snapshots while the request is running.
    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>,
        onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async -> SearchEverywhereResults?

    func searchEverywherePage(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>,
        cursor: String?,
        onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async throws -> SearchEverywhereResults

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: SearchVisibilityRules
    ) -> [ProjectReplacementFile]?

    func readFile(at rootURL: URL, relativePath: String) -> String?
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool
}

public extension SearchOperations {
    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>,
        onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async -> SearchEverywhereResults? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: searchEverywhere(
                    at: rootURL, query: query, options: options, visibilityRules: visibilityRules,
                    includeGeneratedFileNames: includeGeneratedFileNames, kinds: kinds))
            }
        }
    }

    func searchEverywherePage(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>,
        cursor: String?,
        onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async throws -> SearchEverywhereResults {
        guard cursor == nil else { return .init() }
        return await searchEverywhere(at: rootURL, query: query, options: options, visibilityRules: visibilityRules,
            includeGeneratedFileNames: includeGeneratedFileNames, kinds: kinds, onResults: onResults) ?? SearchEverywhereResults()
    }

    func warmSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {}
    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: SearchVisibilityRules) {}
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {}
}
