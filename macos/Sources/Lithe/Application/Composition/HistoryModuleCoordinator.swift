import Combine
import Foundation
import LitheApplicationKernel
import LitheLocalHistoryModule
import LitheModuleAPI

/// Owns activation and per-session configuration of local history.
@MainActor
final class HistoryModuleCoordinator {
    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let workspace: () -> URL?
    private let settings: () -> LocalHistoryVisibilityRules
    private let files: () -> [URL]
    private let documents: () -> [LocalHistoryDocumentSnapshot]
    private let notify: (String) -> Void
    private let onChange: () -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        workspace: @escaping () -> URL?,
        settings: @escaping () -> LocalHistoryVisibilityRules,
        files: @escaping () -> [URL],
        documents: @escaping () -> [LocalHistoryDocumentSnapshot],
        notify: @escaping (String) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.workspace = workspace
        self.settings = settings
        self.files = files
        self.documents = documents
        self.notify = notify
        self.onChange = onChange
    }

    func activate() async -> ProjectHistoryFeatureModel? {
        if let capability: HistoryModuleCapability = store.capability(.historyWorkspace) {
            return capability.feature
        }
        do {
            let value = try await runtime.activateCapability(ModuleCapabilityID.historyWorkspace)
            guard let capability = value as? HistoryModuleCapability else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .localHistory, capability: .historyWorkspace
                )
            }
            let feature = capability.feature
            feature.configure(
                workspaceURLProvider: workspace,
                projectFilesProvider: files,
                documentsProvider: documents
            )
            if let root = workspace() {
                feature.openWorkspace(at: root, visibilityRules: settings())
            }
            store.cache(capability, id: .historyWorkspace, moduleID: .localHistory)
            store.observe(.localHistory, observation: feature.objectWillChange.sink { [weak self] (_: ()) in
                self?.onChange()
            })
            return feature
        } catch {
            notify(error.localizedDescription)
            return nil
        }
    }

    func perform(
        _ action: @escaping @MainActor (ProjectHistoryFeatureModel) async -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let feature = await activate() else { return }
            await action(feature)
        }
    }

    func resetFeature(_ feature: ProjectHistoryFeatureModel?) {
        feature?.reset()
    }
}
