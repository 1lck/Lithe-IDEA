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
    @Published public private(set) var searchEverywhereFailed = false
    @Published public private(set) var searchEverywherePageByID: [String: Int] = [:]
    private var nextSearchPage: (@MainActor () async -> Void)?
    private var searchPageNumber = 0
    @Published public private(set) var projectReplacementFiles: [ProjectReplacementFile] = []
    @Published public private(set) var isLoadingProjectReplacement = false

    private let operations: any SearchOperations
    private var indexTask: Task<Void, Never>?
    private var indexTaskGeneration = 0
    private var everywhereSearchGeneration = 0
    private var everywhereSearchTask: Task<Void, Never>?
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
        clearSearchEverywhere()
        projectReplacementFiles = []
        isLoadingProjectReplacement = false
    }

    public func warmIndex(at workspaceURL: URL, visibilityRules: SearchVisibilityRules) {
        replaceIndexTask { operations in
            operations.warmSearchIndex(at: workspaceURL, visibilityRules: visibilityRules)
        }
    }

    public func invalidateIndex(at workspaceURL: URL, visibilityRules: SearchVisibilityRules) {
        replaceIndexTask(mustComplete: true) { operations in
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
        mustComplete: Bool = false,
        operation: @escaping @Sendable (any SearchOperations) -> Void
    ) {
        let previousTask = indexTask
        previousTask?.cancel()
        let operations = self.operations
        indexTaskGeneration += 1
        let generation = indexTaskGeneration
        let worker = Task.detached(priority: .utility) {
            await previousTask?.value
            guard mustComplete || !Task.isCancelled else { return }
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
        await indexTask?.value
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

    public func cancelSearchEverywhere() {
        everywhereSearchGeneration &+= 1
        everywhereSearchTask?.cancel()
        everywhereSearchTask = nil
        nextSearchPage = nil
        searchEverywhereFailed = false
        isSearchingEverywhere = false
    }

    public func clearSearchEverywhere() {
        cancelSearchEverywhere()
        searchPageNumber = 0
        searchEverywherePageByID = [:]
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
    }

    public func searchEverywhere(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        kinds: Set<SearchResultKind> = [.file, .type, .symbol, .content],
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        clearSearchEverywhere()
        guard !kinds.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = everywhereSearchGeneration
        nextSearchPage = { [weak self] in
            guard let self else { return }
            await self.loadSearchPage(at: workspaceURL, query: query, options: options,
                visibilityRules: visibilityRules, kinds: kinds, generation: generation, isCurrent: isCurrent)
        }
        await nextSearchPage?()
    }

    public func loadNextSearchPage(retry: Bool = false) async {
        guard !isSearchingEverywhere, retry || !searchEverywhereFailed,
              searchEverywhereResults.nextCursor != nil || (retry && searchEverywhereFailed) else { return }
        await nextSearchPage?()
    }

    private func loadSearchPage(at workspaceURL: URL, query: String, options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules, kinds: Set<SearchResultKind>, generation: Int,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard generation == everywhereSearchGeneration, !Task.isCancelled, isCurrent() else { return }
        isSearchingEverywhere = true
        searchEverywhereFailed = false
        defer {
            if generation == everywhereSearchGeneration {
                everywhereSearchTask = nil
                isSearchingEverywhere = false
            }
        }
        await indexTask?.value
        guard generation == everywhereSearchGeneration, !Task.isCancelled, isCurrent() else { return }
        let operations = self.operations
        let cursor = searchEverywhereResults.nextCursor
        let previous = cursor == nil ? SearchEverywhereResults() : searchEverywhereResults
        let pageNumber = searchPageNumber
        // Only the first page streams replacement snapshots. Continuations are
        // appended atomically so later ranking cannot move the visible viewport.
        let (updates, continuation) = AsyncStream.makeStream(
            of: Result<(SearchEverywhereResults, Bool), Error>.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            defer { continuation.finish() }
            do {
                let results = try await operations.searchEverywherePage(
                    at: workspaceURL, query: query, options: options, visibilityRules: visibilityRules,
                    includeGeneratedFileNames: true, kinds: kinds, cursor: cursor,
                    onResults: { if cursor == nil { continuation.yield(.success(($0, false))) } })
                continuation.yield(.success((results, true)))
            } catch { continuation.yield(.failure(error)) }
        }
        everywhereSearchTask = worker
        await withTaskCancellationHandler {
            for await update in updates {
                guard generation == everywhereSearchGeneration, !Task.isCancelled, isCurrent() else {
                    worker.cancel()
                    break
                }
                switch update {
                case .failure:
                    searchEverywhereFailed = true
                case .success(let (results, finished)):
                    func append(_ old: [FileSearchResult], _ incoming: [FileSearchResult]) -> [FileSearchResult] {
                        var ids = Set(old.map(\.id))
                        return old + incoming.filter { ids.insert($0.id).inserted }
                    }
                    let files = append(previous.fileMatches, results.fileMatches)
                    let types = append(previous.classMatches, results.classMatches)
                    let symbols = append(previous.symbolMatches, results.symbolMatches)
                    let contents = append(previous.contentMatches, results.contentMatches)
                    let count = files.count + types.count + symbols.count + contents.count
                    let progressed = count > previous.totalCount && results.nextCursor != cursor
                    let nextCursor = finished ? (progressed ? results.nextCursor : nil) : cursor
                    searchEverywhereResults = .init(fileMatches: files, classMatches: types,
                        symbolMatches: symbols, contentMatches: contents, nextCursor: nextCursor)
                    var pageByID = cursor == nil ? [:] : searchEverywherePageByID
                    for item in results.allMatches where pageByID[item.id] == nil { pageByID[item.id] = pageNumber }
                    searchEverywherePageByID = pageByID
                    if finished { searchPageNumber += 1 }
                }
            }
            await worker.value
        } onCancel: {
            worker.cancel()
            continuation.finish()
        }
    }

    /// File-name matches for a completion list. Unlike Search Everywhere this
    /// leaves the published results untouched; callers drop stale queries.
    public func findFiles(
        at workspaceURL: URL,
        query: String,
        visibilityRules: SearchVisibilityRules
    ) async -> [URL] {
        await indexTask?.value
        let operations = self.operations
        let results = await Task.detached(priority: .userInitiated) {
            operations.searchEverywhere(
                at: workspaceURL,
                query: query,
                options: .default,
                visibilityRules: visibilityRules,
                includeGeneratedFileNames: false,
                kinds: [.file]
            )
        }.value
        return results?.fileMatches.map(\.url) ?? []
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
        saveTextOverride: @escaping @MainActor (URL, String) async throws -> Bool
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
                let savedOverride = try await saveTextOverride(target.url, replacedText)
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
        await indexTask?.value
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
