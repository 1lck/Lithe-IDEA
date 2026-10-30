import Combine
import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheExecutionModule
import LitheModuleAPI

// Note: .agents/notes/implemented/architecture/2026-10-26-build-provider-task-execution.md
@MainActor
extension AppModel {
    /// The Maven Provider prepares its framework goal; Java's existing adapter
    /// attaches to the host-selected endpoint after the process is listening.
    func startProviderFrameworkDebug(_ configuration: RunConfiguration, identity: WorkspaceIdentity,
                                            run: RunFeatureModel) async {
        var operation: String?
        var attached = false
        defer { if !attached, let operation, run.isProviderDebugActive(operation) { run.stopProviderDebug() } }
        do {
            guard services.remoteConnections?.workspaces.contains(identity.url) != true else {
                throw RunConfigurationOperationFailure(message: L10n.string("Framework service debugging is not available in remote workspaces yet."))
            }
            try await saveJavaWorkspaceForLaunch(identity: identity)
            guard isCurrentWorkspace(identity), !Task.isCancelled,
                  let debug = genericDebugFeatureIfActive else { throw CancellationError() }
            runWorkflowCoordinator.reapplySelectedConfiguration(run)
            try await prepareCurrentProviderGeneration(configuration: configuration, identity: identity)
            let sessions = try await languageSessionsForWorkspaceMaintenance(for: identity)
            var javaRevision: UInt64?
            let revision = buildSystemsFeatureIfActive?.inputRevision
            let current: @MainActor @Sendable () -> Bool = { [weak self, weak run] in
                guard let self, let run else { return false }
                return self.isCurrentWorkspace(identity) && !Task.isCancelled
                    && run.selectedConfiguration == configuration && self.buildSystemsFeatureIfActive?.inputRevision == revision
                    && (javaRevision == nil || sessions.javaImportRevision == javaRevision)
            }
            guard current() else { throw CancellationError() }
            let port = try debugPortAvailabilityChecker.unusedLoopbackPort()
            let launched = try await run.prepareProviderDebug(configuration, port: port, languageImport: { [weak self] imported in
                guard let self, current(), case .maven(let context) = imported else { throw CancellationError() }
                let defaults = try self.javaLanguageImportConfiguration(rootURL: identity.url)
                try await sessions.applyJavaRunImport(rootURL: identity.url,
                    languageImport: .init(mavenContext: context, javaGradle: defaults.javaGradle))
                javaRevision = sessions.javaImportRevision
            }, isCurrent: current)
            operation = launched
            showToolWindow(.run)
            try await debugPortAvailabilityChecker.waitForLoopbackListener(port, processID: { run.providerDebugProcessID(launched) }) {
                current() && run.isProviderDebugActive(launched)
            }
            guard current(), run.isProviderDebugActive(launched) else { throw CancellationError() }
            let attach = try debugLaunchConfigurationResolver.resolveJavaAttach(host: "127.0.0.1", port: Int(port))
            let source = runWorkflowCoordinator.sourceURLForDebug(configuration: configuration,
                activeDocument: activeDocument, projectFiles: projectFiles, workspaceURL: identity.url) ?? identity.url
            guard debug.startAdditional(fileURL: source, rootURL: identity.url, configuration: attach),
                  let sessionID = debug.activeSessionID else {
                throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable
            }
            // Clear any previous association before stopping it: callbacks may
            // arrive synchronously and must not stop the replacement process.
            let previous = providerDebugSession
            providerDebugSession = (launched, sessionID)
            if let previous { debug.stopSession(previous.session) }
            providerDebugRunObservation = run.providerDebugEnded.sink { [weak self, weak debug] ended in
                guard let self, let owned = self.providerDebugSession, owned.operation == ended else { return }
                self.providerDebugSession = nil
                debug?.stopSession(owned.session)
            }
            attached = true
            showDebugToolWindow()
        } catch is CancellationError { }
        catch { if isCurrentWorkspace(identity), !Task.isCancelled { showNotification(error.localizedDescription) } }
    }

    func stopProviderDebugProcess(for session: DebugSessionID) {
        guard let owned = providerDebugSession, owned.session == session else { return }
        providerDebugSession = nil
        if runFeatureIfActive?.isProviderDebugActive(owned.operation) == true { runFeatureIfActive?.stopProviderDebug() }
    }

    func debugBuildProviderApplication(entryID: String, request: BuildRunRequest, title: String) {
        runWorkflowCoordinator.startModuleOperation { [weak self] in
            guard let self, let identity = currentWorkspaceIdentity,
                  await saveAllDocuments(), isCurrentWorkspace(identity),
                  await activateDebugModule() != nil, isCurrentWorkspace(identity),
                  !Task.isCancelled, let feature = buildSystemsFeatureIfActive else { return }
            if feature.debugApplication(entryID, request: request, title: title, launch: { [weak self] source, preparation in
                guard let self, self.isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
                try self.launchPreparedProviderDebug(source: source, preparation: preparation, workspaceURL: identity.url, title: title)
            }) != nil { showToolWindow(.buildOutput) }
        }
    }

    func launchPreparedProviderDebug(source: BuildSystemPluginSource, preparation: BuildDebugPreparation,
                                            workspaceURL: URL, title: String) throws {
        guard let feature = genericDebugFeatureIfActive else { throw CancellationError() }
        let configuration = try debugLaunchConfigurationResolver.resolveProvider(source: source, preparation: preparation,
                                                                                 workspaceURL: workspaceURL, title: title)
        guard feature.startAdditional(fileURL: workspaceURL.appendingPathComponent(preparation.program),
                                      rootURL: workspaceURL, configuration: configuration) else {
            throw NSError(domain: "BuildProviderDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: feature.errorMessage
                ?? L10n.string("The build provider's debug program or adapter is unavailable. Build it again and check that the plugin is enabled.")])
        }
        showToolWindow(.debug)
    }

}
