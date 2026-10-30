import Foundation
import LitheApplicationKernel
@testable import LitheLocalHistoryModule
import LitheModuleAPI
import Testing

@MainActor
struct LocalHistoryModuleTests {
    @Test
    func disabledHistoryDoesNotConstructFactory() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: HistoryModule.moduleManifest, contributions: HistoryModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule()
        }, enabled: false)
        await #expect(throws: ModuleRuntimeError.moduleDisabled(.localHistory)) {
            _ = try await runtime.activateCapability(.historyWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
    }

    @Test
    func sleepReleasesFeatureAndWakeReconstructsIt() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: HistoryModule.moduleManifest, contributions: HistoryModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule()
        })
        var first: ProjectHistoryFeatureModel? = try #require((try await runtime.activateCapability(.historyWorkspace) as? HistoryModuleCapability)?.feature)
        weak var released = first
        first = nil
        try await runtime.sleep(.localHistory)
        #expect(released == nil)
        #expect(runtime.capability(.historyWorkspace) == nil)
        #expect(try runtime.snapshot(for: .localHistory).activity.activeResourceCount == 0)
        _ = try #require((try await runtime.activateCapability(.historyWorkspace) as? HistoryModuleCapability)?.feature)
        #expect(recorder.factoryCalls == 2)
    }

    @Test
    func batchPrunesOnceAfterSkippedFileAndPreservesEverySnapshot() async throws {
        let operations = BatchOperations()
        let root = URL(fileURLWithPath: "/in-memory/history")
        let service = LocalHistoryService(workspaceURL: root,
            visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []),
            storage: TestStorage(), operations: operations)
        let files = ["skip"] + (0..<4000).map { "file-\($0)" }
        await service.recordFiles(files.map { root.appendingPathComponent($0) }, reason: .externalChange)
        #expect(operations.calls.map(\.0) == files)
        #expect(operations.calls.map(\.1) == [true, true] + Array(repeating: false, count: 3999))
        await service.recordFiles([root.appendingPathComponent("next")], reason: .externalChange)
        #expect(operations.calls.last?.1 == true)
        _ = try await service.recordFile(at: root.appendingPathComponent("single"), reason: .saved)
        #expect(operations.calls.last?.1 == true)
    }

    @Test
    func cancelledHistoryBatchDoesNotRecordFiles() async {
        let operations = BatchOperations()
        let root = URL(fileURLWithPath: "/in-memory/history")
        let service = LocalHistoryService(workspaceURL: root,
            visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []),
            storage: TestStorage(), operations: operations)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.recordFiles([root.appendingPathComponent("file")], reason: .externalChange)
        }
        await task.value
        #expect(operations.calls.isEmpty)
    }

    private func makeModule() -> HistoryModule {
        HistoryModule(workspaceAccess: TestWorkspaceAccess(), storage: TestStorage(), operations: TestOperations())
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) { EmptyWorkspaceModule() }
    }
}

@MainActor private final class Recorder { var factoryCalls = 0 }
@MainActor private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
private struct TestWorkspaceAccess: LocalHistoryWorkspaceAccess {
    func fileExists(at url: URL) -> Bool { false }
    func readFile(at workspaceURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at workspaceURL: URL, relativePath: String) -> Bool { false }
}
private struct TestStorage: LocalHistoryStorage {
    func applicationSupportDirectory() -> URL { URL(fileURLWithPath: "/tmp/lithe-history-test") }
}
private struct TestOperations: LocalHistoryOperations {
    func record(at workspaceURL: URL, storageURL: URL, relativePath: String, reason: LocalHistoryReason, content: String?, pruneExpired: Bool, visibilityRules: LocalHistoryVisibilityRules) -> LocalHistoryEntryPayload? { nil }
    func entries(at workspaceURL: URL, storageURL: URL, relativePath: String?, visibilityRules: LocalHistoryVisibilityRules) -> [LocalHistoryEntryPayload]? { [] }
    func content(at storageURL: URL, contentPath: String) -> String? { nil }
    func relocate(at storageURL: URL, sourcePath: String, destinationPath: String) -> Bool { false }
}

private final class BatchOperations: LocalHistoryOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, Bool)] = []
    var calls: [(String, Bool)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func record(at workspaceURL: URL, storageURL: URL, relativePath: String, reason: LocalHistoryReason, content: String?, pruneExpired: Bool, visibilityRules: LocalHistoryVisibilityRules) -> LocalHistoryEntryPayload? {
        lock.lock(); defer { lock.unlock() }
        recorded.append((relativePath, pruneExpired))
        guard relativePath != "skip" else { return nil }
        return .init(id: "00000000-0000-0000-0000-000000000001", timestamp: 1,
                     relativePath: relativePath, reason: reason.rawValue, contentPath: "snapshot", byteCount: 1)
    }
    func entries(at workspaceURL: URL, storageURL: URL, relativePath: String?, visibilityRules: LocalHistoryVisibilityRules) -> [LocalHistoryEntryPayload]? { [] }
    func content(at storageURL: URL, contentPath: String) -> String? { nil }
    func relocate(at storageURL: URL, sourcePath: String, destinationPath: String) -> Bool { false }
}
