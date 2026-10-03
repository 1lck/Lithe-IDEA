import AppKit
import LitheApplicationKernel
@testable import LitheDatabaseModule
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

@Suite("Database workspace lifecycle")
@MainActor
struct DatabaseWorkspaceLifecycleTests {
    @Test(arguments: [false, true])
    func retainedViewsRenderAfterProjectSessionShutdown(hasSelectedConnection: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let connectionStore = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Lifecycle fixture", kind: .sqlite, path: "/fixture/lifecycle.sqlite")
        try connectionStore.save([profile])
        let settings = AppSettings(store: preferences)
        let services = MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil),
            connectionStore: connectionStore
        )
        defer { feature.prepareForModuleRelease() }
        if hasSelectedConnection {
            feature.selectedProfileID = profile.id
            feature.workspaceSection = .sql
        }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        model.selectedSidebar = .database

        func content(revision: Int) -> AnyView {
            AnyView(HStack(spacing: 0) {
                DatabaseSidebarView().frame(width: 280)
                DatabaseWorkspaceView().frame(width: 760, height: 550)
            }
            .id(revision)
            .environmentObject(feature)
            .environmentObject(model)
            .environmentObject(settings))
        }
        let host = NSHostingView(rootView: content(revision: 0))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 550),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(model.databaseFeatureIfActive === feature)

        // Keep the native host alive across cache teardown, then force another
        // body evaluation. A parent sidebar guard cannot protect this ordering.
        feature.prepareForModuleRelease()
        await model.shutdownProjectSession()
        #expect(model.databaseFeatureIfActive == nil)
        host.rootView = content(revision: 1)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)

        // Connection and schema sheets can also outlive the workspace subtree.
        host.rootView = AnyView(VStack {
            DatabaseConnectionEditor(isPresented: .constant(true))
            DatabaseSchemaDiffView()
        }.environmentObject(feature)
            .environmentObject(model)
            .environmentObject(settings))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test
    func sleepingModuleStopsResourcesWhileOldPresentationSurvivesAndWakeUsesNewFeature() async throws {
        let runtime = ModuleRuntime()
        let preferences = DatabaseLifecyclePreferences()
        try runtime.register(ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            DatabaseLifecycleWorkspaceModule()
        })
        try runtime.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
            DatabaseModule(
                processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil,
                preferenceStore: preferences, secureStore: DatabaseLifecycleSecrets(),
                recoveryStore: UnavailableDatabaseRecoveryStore(), fileStorage: UnavailableDatabaseFileStorage()
            )
        })
        do {
            var retained: DatabaseFeatureModel? = try #require(
                (try await runtime.activateCapability(.databaseWorkspace) as? DatabaseModuleCapability)?.feature
            )
            weak var released = retained
            retained?.addSQLTab(sql: "SELECT 'old presentation'")

            try await runtime.sleep(.database)
            #expect(runtime.capability(.databaseWorkspace) == nil)
            #expect(try runtime.snapshot(for: .database).activity.activeResourceCount == 0)
            #expect(retained?.hasActiveModuleWork == false)
            #expect(retained?.selectedSQLTab?.sql == "SELECT 'old presentation'")

            let next = try #require(
                (try await runtime.activateCapability(.databaseWorkspace) as? DatabaseModuleCapability)?.feature
            )
            #expect(next !== retained)
            #expect(next.selectedSQLTab?.sql == "")
            retained?.updateSQL("SELECT 'late edit'", in: try #require(retained?.selectedSQLTabID))
            #expect(next.selectedSQLTab?.sql == "")
            retained = nil
            #expect(released == nil, "The old feature must be released when its presentation goes away")
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }
}

@MainActor
private final class DatabaseLifecycleWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct DatabaseLifecycleProcessRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        Issue.record("Rendering database views must not launch a database process")
        return DatabaseProcessResult(output: "", exitCode: 1)
    }
}

private final class DatabaseLifecyclePreferences: KeyValueStore, DatabasePreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct DatabaseLifecycleSecrets: DatabaseSecureStore {
    func read(key: String) -> String? { nil }
    func write(_ value: String, key: String) throws {}
    func delete(key: String) throws {}
}
