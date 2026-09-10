import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Test tool window entry points: discovery, run, and the Java debug-test
/// workflow.
///
/// Discovery is cancellable and identified by an operation ID so a workspace
/// switch or a second refresh cannot let an older projection overwrite the
/// items the current discovery published.
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
        let operationID = javaTestWorkflowState.beginDiscovery()
        javaTestWorkflowState.discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { finishLanguageTestDiscovery(operationID) }
            guard let execution = await activateExecutionModule(),
                  await activateLanguageTestExtensionsIfNeeded(
                      for: projectFiles,
                      testService: execution.tests
                  ),
                  isCurrentLanguageTestDiscovery(operationID) else { return }
            execution.tests.discover(workspaceURL: workspaceURL, files: projectFiles)

            let baseItems = execution.tests.itemsByProviderID["java"] ?? []
            let javaFiles = baseItems.filter { $0.kind == .file && $0.fileURL != nil }
            guard !javaFiles.isEmpty else { return }
            do {
                let sessions = try await languageSessionsForWorkspaceMaintenance()
                let projected = try await javaTestWorkflowState.projectDiscoveredItems(
                    baseItems,
                    workspaceURL: workspaceURL,
                    sessions: sessions,
                    isCurrent: { [weak self] operationID in
                        self?.isCurrentLanguageTestDiscovery(operationID) ?? false
                    },
                    operationID: operationID
                )
                execution.tests.replaceDiscoveredItems(projected, providerID: "java")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentLanguageTestDiscovery(operationID) else { return }
                showNotification(error.localizedDescription)
            }
        }
    }

    func cancelLanguageTestDiscovery() {
        javaTestWorkflowState.cancelDiscovery()
    }

    private func isCurrentLanguageTestDiscovery(_ operationID: UUID) -> Bool {
        javaTestWorkflowState.isCurrentDiscovery(operationID)
    }

    private func finishLanguageTestDiscovery(_ operationID: UUID) {
        javaTestWorkflowState.finishDiscovery(operationID)
    }

    func runTest(providerID: String, scope: LanguageTestScope) {
        guard let workspaceURL else { return }
        showToolWindow(.tests)
        Task { [weak self] in
            guard let self, let execution = await activateExecutionModule() else { return }
            if let ownership = services.pluginCatalog.languageSupports[providerID],
               !(await languageIntelligenceModuleCoordinator.activateTestExtension(
                   ownership.declaration,
                   testService: execution.tests
               )) {
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

    func debugTest(providerID: String, scope: LanguageTestScope) {
        guard let workspaceURL else { return }
        switch javaTestWorkflowState.resolveDebugRequest(providerID: providerID, scope: scope) {
        case .rejected(let message):
            showNotification(message)
            return
        case .resolved(let request):
            startJavaTestDebug(request: request, workspaceURL: workspaceURL)
        }
    }

    private func startJavaTestDebug(
        request: JavaTestDebugRequest,
        workspaceURL: URL
    ) {
        featureGraph.javaTestDebugWorkflow.start(
            request: request,
            state: javaTestWorkflowState,
            prepareDirtyDocument: { [weak self] in
                guard let self else { return false }
                return self.javaTestWorkflowState.prepareDirtyDocument(
                    fileURL: request.fileURL,
                    documents: self.openDocuments,
                    saving: self
                )
            },
            prepareLaunch: { [weak self] in
                guard let self else { throw CancellationError() }
                guard let runFeature = await self.activateExecutionModule()?.runFeature,
                      await self.activateDebugModule()?.genericFeature != nil else {
                    throw CancellationError()
                }
                if let selectedConfiguration = runFeature.selectedConfiguration {
                    runFeature.select(selectedConfiguration)
                }
                let sessions = try await self.languageSessionsForWorkspaceMaintenance()
                return try await self.services.javaTestDebugLaunchService.prepare(
                    fileURL: request.fileURL,
                    testIdentifier: request.testIdentifier,
                    rootURL: workspaceURL,
                    targetResolver: sessions
                )
            },
            startDebug: { [weak self] prepared in
                guard let self,
                      let genericDebugFeature = self.genericDebugFeatureIfActive else {
                    return false
                }
                return genericDebugFeature.start(
                    fileURL: prepared.target.fileURL,
                    rootURL: workspaceURL,
                    configuration: prepared.configuration
                )
            },
            errorMessage: { [weak self] in
                self?.genericDebugFeatureIfActive?.errorMessage
            }
        )
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
        executionModuleCoordinator.stopTests(languageTestServiceIfActive)
    }

    func cancelJavaTestDebugLaunch() {
        javaTestWorkflowState.cancelDebugLaunch()
    }

    func stopJavaTestResultServer() {
        javaTestWorkflowState.stopResultServer()
    }

    func cancelJavaTestWorkflows() {
        cancelLanguageTestDiscovery()
        cancelJavaTestDebugLaunch()
    }

    func cancelJavaWorkspaceWorkflows() {
        cancelJavaLanguageServerPreparation()
        cancelJavaTestWorkflows()
    }
}
