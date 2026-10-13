import Foundation
import LitheCoreContracts
import LitheExecutionModule

@MainActor
extension AppModel {
    func toggleMaven() {
        guard hasMavenProject else {
            showNotification("No Maven project was detected in this workspace")
            workbenchFeature.setVisibility(.maven, isVisible: false)
            return
        }
        guard toggleToolWindow(.maven) else { return }
        Task { [weak self] in
            guard let self, await activateExecutionModule() != nil,
                  let workspaceURL else { return }
            await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
        }
        guard let workspaceURL else { return }
        Task { [weak self] in
            guard let self else { return }
            let capability = await self.activateExecutionModule()
            if capability?.mavenFeature.project == nil {
                await self.loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
        }
    }

    func runMaven(
        phase: MavenLifecyclePhase,
        module: MavenModule?
    ) {
        showToolWindow(.mavenOutput)
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.run(phase: phase, module: module)
        }
    }

    func runMavenGoal(_ goal: String, module: MavenModule?) {
        showToolWindow(.mavenOutput)
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.runCustomGoal(goal, module: module)
        }
    }

    func stopMaven() {
        runWorkflowCoordinator.cancelModuleOperation()
        executionModuleCoordinator.stopFeatures(
            maven: mavenFeatureIfActive,
            run: nil
        )
    }

    func openMavenIssue(_ issue: MavenBuildIssue) {
        guard let fileURL = issue.fileURL,
              workspaceFeature.fileExists(at: fileURL) else { return }
        navigateToEditorLocation(
            url: fileURL.standardizedFileURL,
            line: max(0, (issue.line ?? 1) - 1),
            utf16Column: max(0, (issue.column ?? 1) - 1)
        )
    }

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
