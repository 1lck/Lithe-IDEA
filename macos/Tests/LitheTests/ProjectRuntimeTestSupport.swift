import Foundation
import LitheCoreContracts
@testable import Lithe

/// Runtime selection unit tests use an explicit, isolated source. Persistence
/// and migration are exercised separately against Core and temporary files.
@MainActor
final class InMemoryProjectRuntimeSettingsStore: ProjectRuntimeSettingsStoring {
    var values: [URL: ProjectRuntimeSettingsSnapshot] = [:]
    var failure: (any Error)?
    private var revision = 0
    func load(at workspace: URL, migrateLegacy: Bool) throws -> ProjectRuntimeSettingsSnapshot {
        if let failure { throw failure }
        return values[workspace] ?? ProjectRuntimeSettingsSnapshot(workspaceURL: workspace, settings: ProjectRuntimeSettings(), revision: "missing")
    }
    func save(_ settings: ProjectRuntimeSettings, at workspace: URL,
              expecting snapshot: ProjectRuntimeSettingsSnapshot) throws -> ProjectRuntimeSettingsSnapshot {
        let current = try load(at: workspace, migrateLegacy: false)
        guard snapshot.workspaceURL == workspace, current.revision == snapshot.revision else { throw ProjectRuntimeSettingsStoreError.conflict }
        revision += 1
        let saved = ProjectRuntimeSettingsSnapshot(workspaceURL: workspace, settings: settings, revision: String(revision), hasSavedToolchain: true)
        values[workspace] = saved
        return saved
    }
}

@MainActor
extension ProjectRuntimeService {
    convenience init(runtimeLocator: any RuntimeLocator, store _: any KeyValueStore,
                     toolDiscovery: (any RuntimeToolDiscovery)? = nil,
                     javaSelector: any JavaRuntimeSelecting = RustCoreBridge()) {
        self.init(runtimeLocator: runtimeLocator, settingsStore: InMemoryProjectRuntimeSettingsStore(),
                  toolDiscovery: toolDiscovery, javaSelector: javaSelector)
    }
}
