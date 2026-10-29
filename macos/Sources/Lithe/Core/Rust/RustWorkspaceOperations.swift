import Foundation
import LitheCoreContracts
import LitheSearchModule

typealias WorkspaceOperations = LitheCoreContracts.WorkspaceOperations

struct RustWorkspaceOperations: WorkspaceOperations, Sendable {
    let core: RustCoreBridge
    private let directoryListings = ProjectDirectoryListingCache()

    func invalidateDirectoryListings() {
        directoryListings.invalidate()
    }

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

    func childRows(
        of rows: [FileNode],
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> [String: [FileNode]]? {
        ProjectTreeLoader(
            cache: directoryListings,
            generation: directoryListings.prepare(at: rootURL, rules: visibilityRules)
        ) { directories in
            listDirectories(directories, at: rootURL, visibilityRules: visibilityRules)
        }.childRows(of: rows)
    }

    private func listDirectories(
        _ directories: [URL],
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> [String: [ProjectDirectoryEntry]]? {
        let rootPath = rootURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relativePaths = directories.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            if path == rootPath { return "" }
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        guard let payload = core.listDirectories(
            at: rootURL,
            relativePaths: relativePaths,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        ) else {
            return FileSystemWorkspaceSnapshotBuilder().listDirectories(
                directories,
                at: rootURL,
                visibilityRules: visibilityRules
            )
        }
        func url(for relativePath: String) -> URL {
            relativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(relativePath)
        }
        return Dictionary(
            payload.directories.map { directory in
                (
                    url(for: directory.path).standardizedFileURL.path,
                    directory.children.map {
                        ProjectDirectoryEntry(url: url(for: $0.path), isDirectory: $0.isDirectory, isEmptyDirectory: $0.isDirectory && $0.children?.isEmpty == true)
                    }
                )
            },
            uniquingKeysWith: { first, _ in first }
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
        visibilityRules: FileVisibilityRules,
        includeGeneratedFileNames: Bool = false,
        kinds: Set<SearchResultKind> = [.file, .type, .symbol, .content],
        operationID: String? = nil,
        onEvent: (@Sendable (String) -> Void)? = nil
    ) -> SearchEverywhereResults? {
        core.searchEverywhere(
            at: rootURL,
            query: query,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            maxResults: SearchEverywhereResults.matchLimit,
            maxFileResults: kinds.contains(.file) ? SearchEverywhereResults.providerLimit : 0,
            maxContentResults: kinds.contains(.content) ? SearchEverywhereResults.providerLimit : 0,
            maxSymbolResults: !kinds.isDisjoint(with: [.type, .symbol]) ? SearchEverywhereResults.providerLimit : 0,
            fileMask: options.fileMask,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns,
            includeGeneratedFileNames: includeGeneratedFileNames,
            operationID: operationID, onEvent: onEvent
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
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool = false,
        kinds: Set<SearchResultKind> = [.file, .type, .symbol, .content]
    ) -> SearchEverywhereResults? {
        searchEverywhere(at: rootURL, query: query, options: options, visibilityRules: FileVisibilityRules(searchRules: visibilityRules), includeGeneratedFileNames: includeGeneratedFileNames, kinds: kinds)
    }

    func searchEverywhere(
        at rootURL: URL, query: String, options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>,
        onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async -> SearchEverywhereResults? {
        try? await searchEverywherePage(at: rootURL, query: query, options: options, visibilityRules: visibilityRules,
            includeGeneratedFileNames: includeGeneratedFileNames, kinds: kinds, cursor: nil, onResults: onResults)
    }

    func searchEverywherePage(
        at rootURL: URL, query: String, options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>, cursor: String?,
        onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async throws -> SearchEverywhereResults {
        struct Batch: Decodable {
            let type: String
            let results: RustCoreBridge.SearchResponsePayload?
        }
        let operationID = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    let results = core.searchEverywherePage(
                        at: rootURL, query: query, options: options,
                        hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames, hiddenFilePatterns: visibilityRules.hiddenFilePatterns,
                        includeGeneratedFileNames: includeGeneratedFileNames, kinds: kinds,
                        cursor: cursor, operationID: operationID, onEvent: { raw in
                            cancellation.receive(raw)
                            guard !cancellation.isCancelled,
                                  let batch = try? JSONDecoder().decode(Batch.self, from: Data(raw.utf8)),
                                  batch.type == "searchResults", let results = batch.results else { return }
                            onResults(results.makeEverywhereResults(at: rootURL))
                        })
                    if cancellation.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(with: results.map { $0.makeEverywhereResults(at: rootURL) }) }
                }
            }
        } onCancel: { cancellation.cancel() }
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
