import Foundation
import LitheCoreContracts
import LitheExecutionModule

@MainActor
extension AppModel {
    var isMavenOperationBusy: Bool {
        runWorkflowCoordinator.isModuleOperationStarting
            || mavenFeatureIfActive?.isRunning == true
            || mavenFeatureIfActive?.isReloading == true
    }

    func mavenModuleConfiguration(_ module: MavenModule?, debug: Bool) -> RunConfiguration? {
        guard let run = runFeatureIfActive,
              let context = mavenFeatureIfActive?.launchContext else { return nil }
        return MavenModuleOperations.configuration(
            in: run.configurations, preferredID: run.defaultConfigurationID,
            reactorPath: context.reactorPath, modulePath: module?.relativePath ?? ".", debug: debug
        )
    }

    func startMavenModule(_ module: MavenModule?, debug: Bool) {
        guard !isMavenOperationBusy, let identity = currentWorkspaceIdentity,
              let project = mavenFeatureIfActive?.project else { return }
        runWorkflowCoordinator.startModuleOperation { [weak self] in
            guard let self, isCurrentWorkspace(identity), !Task.isCancelled,
                  let run = await activateExecutionModule()?.runFeature,
                  isCurrentWorkspace(identity), !Task.isCancelled else { return }
            guard case .ready = await ensureRunProjectReady(run, for: identity),
                  isCurrentWorkspace(identity), !Task.isCancelled,
                  mavenFeatureIfActive?.project == project else { return }
            guard let configuration = mavenModuleConfiguration(module, debug: debug) else {
                showNotification("Choose a Run configuration for this Maven module")
                showToolWindow(.run)
                return
            }
            if debug {
                guard genericDebugFeatureIfActive?.isSessionActive != true else { return }
                await startDebuggingAfterActivation(configuration: configuration)
            } else {
                showToolWindow(.run)
                await performStartRunConfiguration(configuration)
            }
        }
    }
}
