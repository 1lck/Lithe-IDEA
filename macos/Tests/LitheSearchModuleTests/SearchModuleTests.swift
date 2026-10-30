import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import LitheSearchModule
import Testing

@MainActor
struct SearchModuleTests {
    @Test
    func disabledSearchDoesNotConstructFactoryOrFeature() async throws {
        let recorder = SearchRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(
            ModuleFactory(manifest: SearchModule.moduleManifest, contributions: SearchModule.moduleContributions) {
                recorder.factoryCalls += 1
                return SearchModule(operations: TestSearchOperations())
            },
            enabled: false
        )

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.search)) {
            _ = try await runtime.activateCapability(.searchWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
    }

    @Test
    func sleepReleasesFeatureAndWakeCreatesANewOne() async throws {
        let recorder = SearchRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: SearchModule.moduleManifest, contributions: SearchModule.moduleContributions) {
            recorder.factoryCalls += 1
            return SearchModule(operations: TestSearchOperations())
        })

        var first: SearchFeatureModel? = try #require(
            (try await runtime.activateCapability(.searchWorkspace) as? SearchModuleCapability)?.feature
        )
        weak var releasedFeature = first
        first = nil
        try await runtime.sleep(.search)

        #expect(releasedFeature == nil)
        #expect(runtime.capability(.searchWorkspace) == nil)
        #expect(try runtime.snapshot(for: .search).activity.activeResourceCount == 0)

        let second = try #require(
            (try await runtime.activateCapability(.searchWorkspace) as? SearchModuleCapability)?.feature
        )
        #expect(second !== releasedFeature)
        #expect(recorder.factoryCalls == 2)
    }

    @Test
    func replacingIndexWorkKeepsTheNewestTaskActiveUntilItFinishes() async throws {
        let operations = BlockingIndexOperations()
        defer {
            operations.finishWarmIndex()
            operations.finishInvalidation()
        }
        let feature = SearchFeatureModel(operations: operations)
        let workspaceURL = URL(fileURLWithPath: "/test-workspace")
        let visibilityRules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])

        feature.warmIndex(at: workspaceURL, visibilityRules: visibilityRules)
        try #require(await operations.waitForWarmIndexStart())

        feature.invalidateIndex(at: workspaceURL, visibilityRules: visibilityRules)
        operations.finishWarmIndex()
        try #require(await operations.waitForInvalidationStart())

        #expect(feature.hasActiveModuleWork)

        operations.finishInvalidation()
        try #require(await waitUntil { !feature.hasActiveModuleWork })
        #expect(operations.completedOperations == ["warm", "invalidate"])
    }

    @Test
    func exclusionInvalidationCannotBeSkippedByAnImmediateWatcherUpdate() async throws {
        let operations = BlockingIndexOperations()
        defer { operations.finishWarmIndex(); operations.finishInvalidation() }
        let feature = SearchFeatureModel(operations: operations)
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/test-workspace")
        let rules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: ["cache/"])
        feature.warmIndex(at: root, visibilityRules: rules)
        try #require(await operations.waitForWarmIndexStart())
        feature.invalidateIndex(at: root, visibilityRules: rules)
        // Stay on the main actor: the following update cancels the queued invalidation before it can start.
        operations.finishWarmIndex()
        operations.finishInvalidation()
        await feature.updateIndex(at: root, changedPaths: ["Name.txt"], visibilityRules: rules)
        #expect(operations.completedOperations == ["warm", "invalidate", "update"])
    }

    @Test
    func partialResultsStayVisibleWhileSearchingAndOldCompletionCannotFinishANewerQuery() async throws {
        let operations = StreamingSearchOperations()
        defer { operations.firstFinish.signal(); operations.secondFinish.signal() }
        let feature = SearchFeatureModel(operations: operations)
        defer { feature.reset() }
        let first = Task { await runSearch(feature, query: "first") }
        defer { first.cancel() }
        try #require(await waitUntil { feature.searchEverywhereResults.fileMatches.first?.preview == "first" })
        #expect(feature.isSearchingEverywhere)
        let second = Task { await runSearch(feature, query: "second") }
        defer { second.cancel() }
        try #require(await waitUntil { feature.searchEverywhereResults.fileMatches.first?.preview == "second" })
        operations.firstFinish.signal()
        await first.value
        #expect(feature.isSearchingEverywhere, "An old completion must not hide the new query's progress")
        #expect(feature.searchEverywhereResults.fileMatches.first?.preview == "second")
        operations.secondFinish.signal()
        await second.value
        #expect(!feature.isSearchingEverywhere)
        #expect(feature.searchEverywhereResults.fileMatches.first?.preview == "second-final")
    }

    @Test(arguments: [false, true])
    func resetAndTaskCancellationRejectLateBatches(reset: Bool) async throws {
        let operations = StreamingSearchOperations()
        defer { operations.firstFinish.signal(); operations.secondFinish.signal() }
        let feature = SearchFeatureModel(operations: operations)
        defer { feature.reset() }
        let request = Task { await runSearch(feature, query: "first") }
        defer { request.cancel() }
        try #require(await waitUntil { !feature.searchEverywhereResults.fileMatches.isEmpty })
        if reset { feature.reset() } else { request.cancel() }
        operations.firstFinish.signal()
        await request.value
        #expect(!feature.isSearchingEverywhere)
        #expect(feature.searchEverywhereResults.fileMatches.first?.preview == (reset ? nil : "first"))
    }

    @Test(arguments: ["normal", "failure", "duplicate", "repeat"])
    func continuationPagesAppendRetryAndStopWithoutATotalCap(mode: String) async throws {
        let operations = PagedSearchOperations(mode: mode)
        let feature = SearchFeatureModel(operations: operations)
        defer { feature.reset() }
        await runSearch(feature, query: "name")
        #expect(feature.searchEverywhereResults.totalCount == 50)
        #expect(feature.searchEverywhereResults.nextCursor == "50")
        await feature.loadNextSearchPage()
        if mode == "failure" {
            #expect(feature.searchEverywhereFailed)
            #expect(feature.searchEverywhereResults.totalCount == 50)
            #expect(feature.searchEverywhereResults.nextCursor == "50")
            await feature.loadNextSearchPage()
            #expect(await operations.calls == 2, "Automatic loading pauses after an error")
            await feature.loadNextSearchPage(retry: true)
            #expect(!feature.searchEverywhereFailed)
        }
        if mode == "duplicate" || mode == "repeat" {
            #expect(feature.searchEverywhereResults.nextCursor == nil)
            #expect(feature.searchEverywhereResults.totalCount == (mode == "duplicate" ? 50 : 100))
            await feature.loadNextSearchPage()
            #expect(await operations.calls == 2)
            return
        }
        for _ in 0..<4 { await feature.loadNextSearchPage() }
        let results = feature.searchEverywhereResults
        #expect(results.totalCount == 257)
        #expect(Set(results.allMatches.map(\.id)).count == 257)
        #expect(results.nextCursor == nil)
        #expect(results.fileMatches.map(\.preview) == (0..<257).map(String.init))
        #expect(results.fileMatches.allSatisfy { feature.searchEverywherePageByID[$0.id] == Int($0.preview)! / 50 })
        let calls = await operations.calls
        await feature.loadNextSearchPage()
        #expect(await operations.calls == calls)
    }

    @Test
    func pendingContinuationIsNotDuplicatedAndCannotAppendToANewerQuery() async throws {
        let operations = PagedSearchOperations(mode: "blocking")
        let feature = SearchFeatureModel(operations: operations)
        defer { operations.pageFinish.signal(); feature.reset() }
        await runSearch(feature, query: "first")
        let page = Task { await feature.loadNextSearchPage() }
        defer { page.cancel() }
        try #require(await operations.pageStarted.waitUntilSignaled(timeout: .seconds(2)))
        await feature.loadNextSearchPage()
        #expect(await operations.calls == 2)
        await runSearch(feature, query: "second")
        operations.pageFinish.signal()
        await page.value
        #expect(feature.searchEverywhereResults.totalCount == 50)
        #expect(feature.searchEverywhereResults.nextCursor == "50")
        #expect(!feature.isSearchingEverywhere)
        #expect(!feature.searchEverywhereFailed)
    }

    private func runSearch(_ feature: SearchFeatureModel, query: String) async {
        await feature.searchEverywhere(at: URL(fileURLWithPath: "/test-workspace"), query: query,
            options: .default, visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []),
            isCurrent: { true })
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(
            manifest: ModuleManifest(
                id: .workspace, displayName: "Workspace", scope: .workspace,
                activationPolicy: .onDemand
            )
        ) { EmptyWorkspaceModule() }
    }
}

@MainActor
private final class SearchRecorder { var factoryCalls = 0 }

@MainActor
private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct TestSearchOperations: SearchOperations {
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>) -> SearchEverywhereResults? { SearchEverywhereResults() }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class BlockingIndexOperations: SearchOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let warmIndexGate = DispatchSemaphore(value: 0)
    private let invalidationGate = DispatchSemaphore(value: 0)
    private let warmIndexStarted = AsyncTestSignal()
    private let invalidationStarted = AsyncTestSignal()
    private var completions: [String] = []

    var completedOperations: [String] { withLock { completions } }

    func warmSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {
        warmIndexStarted.signal()
        _ = warmIndexGate.wait(timeout: .now() + 5)
        withLock { completions.append("warm") }
    }

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {
        invalidationStarted.signal()
        _ = invalidationGate.wait(timeout: .now() + 5)
        withLock { completions.append("invalidate") }
    }

    func waitForWarmIndexStart() async -> Bool {
        await warmIndexStarted.waitUntilSignaled()
    }

    func waitForInvalidationStart() async -> Bool {
        await invalidationStarted.waitUntilSignaled()
    }

    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: SearchVisibilityRules) {
        withLock { completions.append("update") }
    }

    func finishWarmIndex() {
        warmIndexGate.signal()
    }

    func finishInvalidation() {
        invalidationGate.signal()
    }

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>) -> SearchEverywhereResults? { SearchEverywhereResults() }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class AsyncTestSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func signal() {
        continuation.yield()
        continuation.finish()
    }

    func waitUntilSignaled(timeout: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for an event-driven test signal.
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

/// Deliberately returns late callbacks even after cancellation to exercise the
/// feature's generation boundary independently of Core's cooperative cancellation.
private final class StreamingSearchOperations: SearchOperations, @unchecked Sendable {
    let firstFinish = DispatchSemaphore(value: 0)
    let secondFinish = DispatchSemaphore(value: 0)

    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>, onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async -> SearchEverywhereResults? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                func results(_ text: String) -> SearchEverywhereResults {
                    .init(fileMatches: [.init(url: rootURL.appendingPathComponent(text), line: nil, preview: text, kind: .file)])
                }
                onResults(results(query))
                let gate = query == "first" ? firstFinish : secondFinish
                #expect(gate.wait(timeout: .now() + 5) == .success)
                // A fast source can outrun the main actor; the final response must win.
                for index in 0..<300 { onResults(results("\(query)-late-\(index)")) }
                continuation.resume(returning: results(query + "-final"))
            }
        }
    }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>) -> SearchEverywhereResults? { nil }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private actor PagedSearchOperations: SearchOperations {
    let pageStarted = AsyncTestSignal()
    let pageFinish = DispatchSemaphore(value: 0)
    let mode: String
    var calls = 0
    init(mode: String) { self.mode = mode }
    nonisolated func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    nonisolated func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>) -> SearchEverywhereResults? { .init() }
    func searchEverywherePage(at rootURL: URL, query: String, options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>,
        cursor: String?, onResults: @escaping @Sendable (SearchEverywhereResults) -> Void
    ) async throws -> SearchEverywhereResults {
        calls += 1
        if mode == "failure" && calls == 2 { throw NSError(domain: "search-test", code: 1) }
        if mode == "blocking" && cursor != nil {
            pageStarted.signal()
            let gate = pageFinish
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    #expect(gate.wait(timeout: .now() + 2) == .success)
                    continuation.resume()
                }
            }
        }
        let start = mode == "duplicate" ? 0 : Int(cursor ?? "0")!
        let end = min(start + 50, 257)
        let matches = (start..<end).map { FileSearchResult(url: rootURL.appendingPathComponent("name\($0)"),
            line: nil, preview: String($0), kind: .file) }
        // A continuation's provisional snapshot must never replace already loaded rows.
        onResults(.init(fileMatches: [FileSearchResult(url: rootURL.appendingPathComponent("provisional"), line: nil, preview: "provisional", kind: .file)]))
        return .init(fileMatches: matches, nextCursor: end == 257 ? nil : (mode == "repeat" && cursor != nil ? cursor : String(mode == "duplicate" ? calls * 50 : end)))
    }
    nonisolated func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    nonisolated func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    nonisolated func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}
