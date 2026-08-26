import Foundation
import LitheModuleAPI

/// Keeps native plugin code marked for the full process lifetime. If the mark
/// survives, the next launch quarantines those modules before loading a Bundle.
@MainActor
final class MacPluginRuntimeRecoveryCoordinator {
    private var didRecoverPreviousSession = false
    private var loadedModuleIDs: Set<ModuleID> = []

    func recoverPreviousSession(using store: any ModuleRecoveryStore) {
        guard !didRecoverPreviousSession else { return }
        let interruptedModuleIDs = store.pendingPluginLoadModules()
        for moduleID in interruptedModuleIDs {
            store.setQuarantined(true, for: moduleID)
        }
        store.setPendingPluginLoadModules([])
        didRecoverPreviousSession = true
    }

    func prepareToLoad(
        _ moduleIDs: [ModuleID],
        using store: any ModuleRecoveryStore
    ) {
        recoverPreviousSession(using: store)
        store.setPendingPluginLoadModules(
            loadedModuleIDs.union(moduleIDs).sorted()
        )
    }

    func recordSuccessfulLoad(
        _ moduleIDs: [ModuleID],
        using store: any ModuleRecoveryStore
    ) {
        loadedModuleIDs.formUnion(moduleIDs)
        store.setPendingPluginLoadModules(loadedModuleIDs.sorted())
    }

    func recordFailedLoad(using store: any ModuleRecoveryStore) {
        store.setPendingPluginLoadModules(loadedModuleIDs.sorted())
    }

    func recordCleanShutdown(using store: any ModuleRecoveryStore) {
        loadedModuleIDs.removeAll()
        store.setPendingPluginLoadModules([])
    }
}
