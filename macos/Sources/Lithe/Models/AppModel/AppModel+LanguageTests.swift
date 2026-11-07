import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Test tool window entry points: discovery and run.
///
/// Discovery is cancellable and identified by an operation ID so a workspace
/// switch or a second refresh cannot let an older discovery overwrite the
/// items the current one published.
@MainActor
extension AppModel {
    func toggleTests() {
        guard toggleToolWindow(.tests) else {
            cancelLanguageTestDiscovery()
            return
        }
        guard let workspaceURL else { return }
        startLanguageTestDiscovery(workspaceURL: workspaceURL)
    }

    func refreshTests() {
        guard let workspaceURL else { return }
        startLanguageTestDiscovery(workspaceURL: workspaceURL)
    }

    private func startLanguageTestDiscovery(workspaceURL: URL) {
        guard let identity = currentWorkspaceIdentity, identity.url == workspaceURL.standardizedFileURL else { return }
        let operationID = languageTestWorkflowState.beginDiscovery()
        languageTestWorkflowState.discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { finishLanguageTestDiscovery(operationID) }
            guard let execution = await activateExecutionModule(),
                  await activateLanguageTestExtensionsIfNeeded(
                      for: projectFiles,
                      testService: execution.tests
                  ),
                  isCurrentWorkspace(identity), isCurrentLanguageTestDiscovery(operationID) else { return }
            execution.tests.discover(workspaceURL: workspaceURL, files: projectFiles)
        }
    }

    func cancelLanguageTestDiscovery() {
        languageTestWorkflowState.cancelDiscovery()
    }

    private func isCurrentLanguageTestDiscovery(_ operationID: UUID) -> Bool {
        languageTestWorkflowState.isCurrentDiscovery(operationID)
    }

    private func finishLanguageTestDiscovery(_ operationID: UUID) {
        languageTestWorkflowState.finishDiscovery(operationID)
    }

    func runTest(providerID: String, scope: LanguageTestScope) {
        guard let workspaceURL, let identity = currentWorkspaceIdentity else { return }
        activeTestTarget = ActiveTestTarget(providerID: providerID, scope: scope)
        showToolWindow(.tests)
        let preparationID = languageTestWorkflowState.beginRunPreparation()
        languageTestWorkflowState.runPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { languageTestWorkflowState.finishRunPreparation(preparationID) }
            guard let execution = await activateExecutionModule(), languageTestWorkflowState.isCurrentRunPreparation(preparationID) else { return }
            if let ownership = services.pluginCatalog.languageSupports[providerID],
               !(await languageIntelligenceModuleCoordinator.activateTestExtension(
                   ownership.declaration,
                   testService: execution.tests
               )) {
                return
            }
            guard isCurrentWorkspace(identity), languageTestWorkflowState.isCurrentRunPreparation(preparationID) else { return }
            // A test the build provider reported earlier is rerun by the same
            // provider, through the reference it published with the result.
            if let reference = scope.buildReference, let builds = execution.buildSystems {
                execution.tests.runUsingBackend(providerID: providerID, scope: scope, workspaceURL: workspaceURL,
                    label: L10n.string("Tests")) { [weak self, weak builds] output, process in
                    guard let self, let builds, isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
                    return try await builds.performLanguageTests(reference: reference, workspace: workspaceURL, title: L10n.string("Tests"),
                        isCurrent: { [weak self] in self?.isCurrentWorkspace(identity) == true }, beforePreparing: {
                            guard await self.saveAllDocuments(), self.isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
                            try await self.awaitBuildSystemDetection()
                        }, output: output, process: process)
                }
                return
            }
            _ = execution.tests.run(
                providerID: providerID,
                scope: scope,
                workspaceURL: workspaceURL,
                projectFiles: projectFiles
            )
        }
    }

    private func activateLanguageTestExtensionsIfNeeded(
        for files: [URL],
        testService: LanguageTestService
    ) async -> Bool {
        await languageIntelligenceModuleCoordinator.activateTestExtensions(
            for: files,
            testService: testService,
            supports: { [pluginCatalog = services.pluginCatalog] files in
                pluginCatalog.languageSupports(
                    recognizingProjectFileNames: files.map(\.lastPathComponent)
                ).map(\.declaration)
            }
        )
    }

    func stopTests() {
        languageTestWorkflowState.cancelRunPreparation()
        executionModuleCoordinator.stopTests(languageTestServiceIfActive)
    }

    func cancelLanguageTestWorkflows() {
        languageTestWorkflowState.cancelRunPreparation()
        cancelLanguageTestDiscovery()
    }
}
