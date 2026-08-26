import Foundation
import LitheApplicationKernel
@testable import LitheDatabaseModule
import LitheModuleAPI
import Testing

@MainActor
struct DatabaseModuleTests {
    @Test
    func disabledDatabaseDoesNotConstructFactoryOrPorts() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.database)) {
            _ = try await runtime.activateCapability(.databaseWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.portGraphCalls == 0)
        #expect(try !runtime.snapshot(for: .database).isInstantiated)
    }

    @Test
    func sleepReleasesTimerFeatureAndWakeReconstructsGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        })
        try await runtime.setEnabled(true, for: .database)

        var first: DatabaseFeatureModel? = try #require(
            (try await runtime.activateCapability(.databaseWorkspace) as? DatabaseModuleCapability)?.feature
        )
        weak var released = first
        first = nil
        try await runtime.sleep(.database)

        #expect(released == nil)
        #expect(runtime.capability(.databaseWorkspace) == nil)
        #expect(try runtime.snapshot(for: .database).activity.activeResourceCount == 0)

        let second = try #require(
            (try await runtime.activateCapability(.databaseWorkspace) as? DatabaseModuleCapability)?.feature
        )
        #expect(second !== released)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.portGraphCalls == 2)
    }

    @Test
    func releaseCancelsScheduledBackupWithoutAdvancingSchedule() async throws {
        let preferences = TestPreferences()
        let secrets = TestSecrets()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let profile = DatabaseProfile(name: "Scheduled", kind: .sqlite, path: "/tmp/test.sqlite")
        let dueAt = Date(timeIntervalSince1970: 1)
        try store.save([profile])
        try store.saveBackupSchedules([
            DatabaseBackupSchedule(profileID: profile.id, nextRunAt: dueAt)
        ])
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: TestProcessRunner(), executableURL: nil),
            connectionStore: store
        )

        feature.runScheduledBackups(now: Date(timeIntervalSince1970: 2))
        #expect(feature.hasActiveModuleWork)

        feature.prepareForModuleRelease()
        #expect(!feature.hasActiveModuleWork)
        await Task.yield()
        #expect(feature.backupSchedules.first?.nextRunAt == dueAt)
    }

    private func makeModule(recorder: Recorder) -> DatabaseModule {
        recorder.portGraphCalls += 1
        return DatabaseModule(
            processRunner: TestProcessRunner(), executableURL: nil,
            preferenceStore: TestPreferences(), secureStore: TestSecrets(),
            recoveryStore: UnavailableDatabaseRecoveryStore(),
            fileStorage: UnavailableDatabaseFileStorage()
        )
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyWorkspaceModule()
        }
    }
}

@MainActor private final class Recorder { var factoryCalls = 0; var portGraphCalls = 0 }
@MainActor private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
private struct TestProcessRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult { DatabaseProcessResult(output: "", exitCode: 0) }
}
private final class TestPreferences: DatabasePreferenceStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
}
private struct TestSecrets: DatabaseSecureStore {
    func read(key: String) -> String? { nil }
    func write(_ value: String, key: String) throws {}
    func delete(key: String) throws {}
}
