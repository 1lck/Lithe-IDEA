import Foundation
import LitheApplicationKernel
import LitheLocalHistoryModule
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
        weak let released = first
        first = nil
        try await runtime.sleep(.localHistory)
        #expect(released == nil)
        #expect(runtime.capability(.historyWorkspace) == nil)
        #expect(try runtime.snapshot(for: .localHistory).activity.activeResourceCount == 0)
        _ = try #require((try await runtime.activateCapability(.historyWorkspace) as? HistoryModuleCapability)?.feature)
        #expect(recorder.factoryCalls == 2)
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
