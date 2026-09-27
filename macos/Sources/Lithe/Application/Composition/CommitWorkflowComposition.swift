import LitheCoreContracts
import LitheGitModule
import LitheModuleAPI

extension GitFeatureModel: CommitWorkflowGit {
    var stagedChangeIDs: Set<String> {
        Set(gitChanges.filter(\.isStaged).map(\.id))
    }
}

@MainActor
enum CommitWorkflowComposition {
    static func make(model: AppModel) -> CommitWorkflowCoordinator {
        let runtime = model.services.moduleRuntime
        let settings = model.settings
        let workspace = model.workspaceFeature
        let notification = model.notificationFeature
        return CommitWorkflowCoordinator(
            draft: model.commitDraftFeature,
            activateGit: { [weak model] in await model?.activateGitModule() },
            workspaceGeneration: { workspace.workspaceGeneration },
            generate: { [weak model] input in
                model?.refreshAIConfigurations()
                let value = try await runtime.activateCapability(.aiCommitMessage)
                defer { try? runtime.markIdle(.aiAssistance) }
                guard let capability = value as? any AICommitMessageGenerating else {
                    throw ModuleRuntimeError.missingCapabilityDependency(
                        module: .aiAssistance, capability: .aiCommitMessage
                    )
                }
                return try await capability.generateCommitMessage(
                    input: input, settings: settings.commitMessageAI
                )
            },
            notify: { notification.show($0) }
        )
    }
}
