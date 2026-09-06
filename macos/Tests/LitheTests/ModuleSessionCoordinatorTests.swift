import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Module session coordination")
@MainActor
struct ModuleSessionCoordinatorTests {
    @Test
    func releaseEventsClearOnlyTheirModuleAndRestoreTheDatabaseSidebar() {
        let runtime = ModuleRuntime()
        let store = ModuleCapabilityStore()
        let workbench = WorkbenchFeatureModel()
        let database = SessionTestCapability()
        let git = SessionTestCapability()
        store.cache(database, id: .databaseWorkspace, moduleID: .database)
        store.cache(git, id: .gitWorkspace, moduleID: .git)
        workbench.selectedSidebar = .database
        var released: [ModuleID] = []
        var changes = 0
        let coordinator = ModuleSessionCoordinator(
            runtime: runtime, capabilities: store, workbench: workbench,
            onModuleReleased: { released.append($0) },
            onChange: { changes += 1 }
        )
        defer { coordinator.stopObserving() }

        runtime.publish(ModuleEvent(source: .database, name: "module.sleeping"))

        #expect(store.capability(.databaseWorkspace, as: SessionTestCapability.self) == nil)
        #expect(store.capability(.gitWorkspace) === git)
        #expect(workbench.selectedSidebar == .project)
        #expect(released == [.database])
        #expect(changes == 1)
        runtime.publish(ModuleEvent(source: .git, name: ModuleEvent.stateChangedName))
        #expect(changes == 2)
        #expect(released == [.database])

        coordinator.stopObserving()
        coordinator.stopObserving()
        runtime.publish(ModuleEvent(source: .git, name: "module.shutdown"))
        #expect(store.capability(.gitWorkspace) === git)
        #expect(changes == 2)
    }

    @Test
    func repeatedShutdownRequestsShareWorkAndWaitersResumeAfterCleanup() async {
        let started = TestGate()
        let release = TestGate()
        let store = ModuleCapabilityStore()
        store.cache(SessionTestCapability(), id: .databaseWorkspace, moduleID: .database)
        var shutdowns = 0
        var released: [ModuleID] = []
        let coordinator = ModuleSessionCoordinator(
            runtime: ModuleRuntime(), capabilities: store, workbench: WorkbenchFeatureModel(),
            onModuleReleased: { released.append($0) },
            onChange: {},
            shutdownRuntime: {
                shutdowns += 1
                started.open()
                #expect(await release.waitUntilOpen(), "Shutdown was not released")
            }
        )
        defer {
            release.open()
            coordinator.stopObserving()
        }
        coordinator.beginShutdown()
        coordinator.beginShutdown()
        #expect(await started.waitUntilOpen())
        #expect(shutdowns == 1)
        #expect(released.isEmpty)
        #expect(store.capability(.databaseWorkspace, as: SessionTestCapability.self) != nil)

        release.open()
        await coordinator.awaitShutdown()
        #expect(released == [.database])
        #expect(store.capability(.databaseWorkspace, as: SessionTestCapability.self) == nil)

        await coordinator.shutdown()
        #expect(shutdowns == 2)
        #expect(released == [.database, .database])
    }

    @Test
    func releasingCoordinatorDoesNotCancelRuntimeCleanup() async {
        let started = TestGate()
        let release = TestGate()
        let finished = TestGate()
        var coordinator: ModuleSessionCoordinator? = ModuleSessionCoordinator(
            runtime: ModuleRuntime(), capabilities: ModuleCapabilityStore(),
            workbench: WorkbenchFeatureModel(), onModuleReleased: { _ in }, onChange: {},
            shutdownRuntime: {
                started.open()
                defer { finished.open() }
                #expect(await release.waitUntilOpen(), "Shutdown was not released")
                #expect(!Task.isCancelled)
            }
        )
        defer { release.open() }
        coordinator?.beginShutdown()
        #expect(await started.waitUntilOpen())
        coordinator = nil
        release.open()
        #expect(await finished.waitUntilOpen())
    }
}

private final class SessionTestCapability {}
