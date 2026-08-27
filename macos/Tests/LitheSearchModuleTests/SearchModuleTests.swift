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
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { SearchEverywhereResults() }
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

    func finishWarmIndex() {
        warmIndexGate.signal()
    }

    func finishInvalidation() {
        invalidationGate.signal()
    }

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { SearchEverywhereResults() }
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
