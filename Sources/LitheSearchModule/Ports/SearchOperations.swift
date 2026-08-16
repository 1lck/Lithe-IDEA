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
        visibilityRules: SearchVisibilityRules
    ) -> SearchEverywhereResults?

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
    func warmSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {}
    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: SearchVisibilityRules) {}
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {}
}
