import Foundation
import LitheCoreContracts
import LitheSearchModule

typealias WorkspaceOperations = LitheCoreContracts.WorkspaceOperations

struct RustWorkspaceOperations: WorkspaceOperations, Sendable {
    let core: RustCoreBridge

    func snapshot(
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> WorkspaceSnapshot? {
        if let snapshot = core.snapshot(
            at: rootURL,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeSnapshot(at: rootURL) {
            return snapshot
        }
        return FileSystemWorkspaceSnapshotBuilder().snapshot(
            at: rootURL,
            visibilityRules: visibilityRules
        )
    }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? {
        core.search(
            at: rootURL,
            query: query,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            fileMask: options.fileMask,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeResults(at: rootURL)
    }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? {
        core.searchEverywhere(
            at: rootURL,
            query: query,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            maxResults: SearchEverywhereResults.matchLimit,
            maxFileResults: 50,
            maxContentResults: 50,
            maxSymbolResults: 50,
            fileMask: options.fileMask,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeEverywhereResults(at: rootURL)
    }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? {
        core.previewReplacement(
            at: rootURL,
            query: query,
            replacement: replacement,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            preserveCase: options.preserveCase,
            fileMask: options.fileMask,
            paths: paths,
            textOverrides: textOverrides,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeModels(at: rootURL)
    }

    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {
        core.warmSearchIndex(
            at: rootURL,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func updateSearchIndex(
        at rootURL: URL,
        changedPaths: [String],
        visibilityRules: FileVisibilityRules
    ) {
        core.updateSearchIndex(
            at: rootURL,
            changedPaths: changedPaths,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {
        core.invalidateSearchIndex(
            at: rootURL,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        core.readFile(at: rootURL, relativePath: relativePath)?.text
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        core.writeFile(text, at: rootURL, relativePath: relativePath) != nil
    }
}

extension RustWorkspaceOperations: SearchOperations {
    func warmSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {
        warmSearchIndex(at: rootURL, visibilityRules: FileVisibilityRules(searchRules: visibilityRules))
    }

    func updateSearchIndex(
        at rootURL: URL,
        changedPaths: [String],
        visibilityRules: SearchVisibilityRules
    ) {
        updateSearchIndex(
            at: rootURL,
            changedPaths: changedPaths,
            visibilityRules: FileVisibilityRules(searchRules: visibilityRules)
        )
    }

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {
        invalidateSearchIndex(at: rootURL, visibilityRules: FileVisibilityRules(searchRules: visibilityRules))
    }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules
    ) -> [FileSearchResult]? {
        search(at: rootURL, query: query, options: options, visibilityRules: FileVisibilityRules(searchRules: visibilityRules))
    }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules
    ) -> SearchEverywhereResults? {
        searchEverywhere(at: rootURL, query: query, options: options, visibilityRules: FileVisibilityRules(searchRules: visibilityRules))
    }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: SearchVisibilityRules
    ) -> [ProjectReplacementFile]? {
        previewReplacement(
            at: rootURL, query: query, replacement: replacement, options: options,
            paths: paths, textOverrides: textOverrides,
            visibilityRules: FileVisibilityRules(searchRules: visibilityRules)
        )
    }
}
