import Combine
import LitheSearchModule

@MainActor
enum SearchWorkflowComposition {
    static func make(model: AppModel) -> SearchWorkflowCoordinator {
        SearchWorkflowCoordinator(
            session: model.searchSessionFeature,
            settings: model.settings,
            activate: { [weak model] in
                guard let model, let feature = await model.activateSearchModule() else {
                    throw CancellationError()
                }
                return feature
            },
            workspace: { [weak model] in model?.workspaceURL },
            notify: { [weak model] in model?.showNotification($0) },
            markIdle: { [weak model] in try? model?.services.moduleRuntime.markIdle(.search) }
        )
    }
}
