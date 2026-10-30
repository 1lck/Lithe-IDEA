import LitheModuleAPI
import Foundation
import LitheCoreContracts

@MainActor
extension AppModel {
    func chooseLanguageServerExecutable(providerName: String) -> URL? {
        platformUI.chooseFile(
            title: settings.language.localizedFormat("native.inline.chooseArg1LanguageServer", String(describing: providerName)),
            prompt: settings.language.localizedString("native.inline.choose")
        )
    }

    func openLanguageServerDownload(_ url: URL) {
        platformUI.open(url)
    }

    func languageServerToolConfigurationDidChange(providerID: String) {
        languageToolingFeature.toolConfigurationDidChange(providerID: providerID)
    }

    func isLanguageServerDisabledInCurrentWorkspace(providerID: String) -> Bool {
        languageToolingFeature.isDisabled(providerID)
    }

    func setLanguageServerEnabled(_ enabled: Bool, providerID: String) {
        if providerID == "java", !enabled {
            javaLanguageServerPreparationCoordinator.cancelMavenConfigurationSynchronization()
            cancelJavaLanguageServerPreparation()
        }
        languageToolingFeature.setEnabled(enabled, providerID: providerID)
        if !enabled {
            runFeatureIfActive?.unregisterDependencySource(languageID: providerID)
        } else if let support = services.pluginCatalog.languageSupports[providerID]?.declaration {
            registerLanguageDependencySourceIfAvailable(support: support)
        }
        if providerID == "java", enabled { registerJavaDependencySourceIfAvailable() }
        if providerID == "java", enabled, let workspaceURL {
            prepareJavaLanguageServerForWorkspaceIfNeeded(at: workspaceURL, files: projectFiles)
        }
    }

    func disableLanguageServerForCurrentWorkspace(providerID: String) {
        setLanguageServerEnabled(false, providerID: providerID)
    }

    func prepareJavaLanguageServerRuntimeIfNeeded(
        for document: EditorDocument
    ) -> JavaLanguageServerActivationReadiness {
        if services.projectRuntimeService.isJavaLanguageServerRuntimePrepared(),
           !isBuildLanguageImportPending || languageToolingSessionsIfActive?.activeLanguageServerIDs.contains("java") == true {
            return .ready
        }
        guard !javaFeature.isLanguageServerPreparing, let workspaceURL else { return .preparing }
        prepareJavaLanguageServerForWorkspaceIfNeeded(
            at: workspaceURL,
            files: projectFiles,
            fallbackDocument: document
        )
        return .preparing
    }

    func prepareJavaLanguageServerForWorkspaceIfNeeded(
        at workspaceURL: URL,
        files: [URL],
        fallbackDocument: EditorDocument? = nil
    ) {
        let normalizedRoot = workspaceURL.standardizedFileURL
        guard let identity = currentWorkspaceIdentity, identity.url == normalizedRoot,
              !languageToolingFeature.isDisabled("java") else { return }
        guard services.javaMavenOperations.javaWorkspacePolicy(
            at: normalizedRoot,
            files: files,
            changedFiles: []
        )?.shouldStart == true else { return }
        guard !javaFeature.languageServerStateBelongs(to: normalizedRoot) else { return }

        cancelJavaLanguageServerPreparation()
        let operationID = UUID()
        let owner = javaFeature.beginLanguageServerPreparation(
            workspaceURL: normalizedRoot,
            operationID: operationID
        )
        showJavaLanguageServerPreparingNotification()
        javaLanguageServerPreparationCoordinator.prepareAndStart(
            owner: owner,
            workspaceURL: normalizedRoot,
            runtimePreparation: { [weak self] in
                guard let self else { return .unprepared }
                return await self.services.projectRuntimeService
                    .prepareJavaLanguageServerRuntime()
            },
            sessionsProvider: { [weak self] in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.languageSessionsForWorkspaceMaintenance(for: identity)
            },
            languageImportPreparation: { [weak self] in
                guard let self, self.isCurrentWorkspace(identity) else { throw CancellationError() }
                try await self.prepareBuildLanguageImport()
                guard self.isCurrentWorkspace(identity) else { throw CancellationError() }
            },
            ownsPreparation: { [weak self] in
                guard let self else { return false }
                return self.ownsJavaLanguageServerPreparation(
                    workspaceURL: normalizedRoot,
                    operationID: operationID
                )
            },
            onStarted: { [weak self, weak fallbackDocument] startedOperationID in
                guard let self else { return }
                if startedOperationID != operationID {
                    owner.operationID = startedOperationID
                    if let currentState = self.languageToolingSessionsIfActive?
                        .languageServerStates["java"] {
                        self.handleJavaLanguageServerState(
                            currentState,
                            operationID: startedOperationID
                        )
                    }
                }
                if let fallbackDocument,
                   fallbackDocument.url.pathExtension.lowercased() == "java" {
                    _ = self.activateLanguageServerIfAvailable(for: fallbackDocument)
                }
            },
            onFailure: { [weak self] failure in
                self?.failJavaLanguageServerPreparation(
                    workspaceURL: normalizedRoot,
                    operationID: operationID,
                    failure: failure
                )
            }
        )
    }

    func cancelJavaLanguageServerPreparation() {
        cancelPendingJavaLaunchDecision()
        if case .preparing(let owner) = javaFeature.languageServerWorkspaceState {
            languageToolingSessionsIfActive?.recordLanguageServerLog(
                providerID: "java",
                operationID: owner.operationID,
                level: .warning,
                message: L10n.string("Java workspace preparation cancelled"),
                detail: nil
            )
            javaFeature.cancelLanguageServerPreparation()
            return
        }
        javaFeature.cancelLanguageServerPreparation()
    }

    func handleJavaLanguageServerState(
        _ state: LanguageServerSessionState,
        operationID: UUID?
    ) {
        switch state {
        case .ready:
            registerJavaDependencySourceIfAvailable()
        case .stopped, .failed:
            runFeatureIfActive?.unregisterDependencySource(languageID: "java")
        case .startingProcess, .initializing, .stopping:
            break
        }
        let currentWorkspaceURL = workspaceURL
        javaLanguageServerPreparationCoordinator.handleSessionState(
            state,
            operationID: operationID,
            javaFeature: javaFeature,
            workspaceURL: workspaceURL,
            onReady: { [weak self] in
                self?.showNotification("Java service is ready")
            },
            onFailure: { [weak self] failure in
                guard let self, let operationID, let currentWorkspaceURL else { return }
                self.failJavaLanguageServerPreparation(
                    workspaceURL: currentWorkspaceURL,
                    operationID: operationID,
                    failure: failure
                )
            }
        )
    }

    func isJavaLanguageServerPreparing(for fileURL: URL) -> Bool {
        guard fileURL.pathExtension.lowercased() == "java" else { return false }
        switch languageToolingSessionsIfActive?.languageServerStates["java"] {
        case .startingProcess, .initializing: return true
        default: break
        }
        return javaFeature.isLanguageServerPreparing
    }

    func showJavaLanguageServerPreparingNotification() {
        showNotification("Java service is preparing")
    }

    func handleWorkspaceFileChanges(_ changes: [WorkspaceFileChange]) {
        guard let workspaceURL else { return }
        runFeatureIfActive?.markDependencyFilesChanged(changes)
        handleBuildSystemFileChanges(changes)
        handleVcsProviderFileChanges(changes)
        let forwarded = changes.filter { change in
            if Self.isWorkspaceDependencyMetadata(
                change.fileURL,
                workspaceURL: workspaceURL
            ) {
                return false
            }
            return true
        }
        javaLanguageServerPreparationCoordinator.notifyWorkspaceFileChanges(
            forwarded,
            workspaceURL: workspaceURL,
            projectFiles: projectFiles,
            openDocuments: openDocuments,
            policy: { rootURL, files, changedFiles in
                self.services.javaMavenOperations.javaWorkspacePolicy(
                    at: rootURL,
                    files: files,
                    changedFiles: changedFiles
                )
            },
            sessions: languageToolingSessionsIfActive
        )
    }

    private static func isWorkspaceDependencyMetadata(
        _ fileURL: URL,
        workspaceURL: URL
    ) -> Bool {
        let directory = workspaceURL.standardizedFileURL
            .appendingPathComponent(".lithe", isDirectory: true)
            .appendingPathComponent("dependencies", isDirectory: true)
            .standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        return path == directory || path.hasPrefix(directory + "/")
    }

    private func ownsJavaLanguageServerPreparation(
        workspaceURL: URL,
        operationID: UUID
    ) -> Bool {
        !languageToolingFeature.isDisabled("java") && javaFeature.ownsLanguageServerPreparation(
            workspaceURL: workspaceURL,
            operationID: operationID,
            activeWorkspaceURL: self.workspaceURL
        )
    }

    private func failJavaLanguageServerPreparation(
        workspaceURL: URL,
        operationID: UUID,
        failure: JavaLanguageServerPreparationFailure
    ) {
        javaFeature.markLanguageServerFailed(
            workspaceURL: workspaceURL,
            operationID: operationID,
            failure: failure
        )
        switch failure {
        case .timedOut:
            showNotification("Java service preparation timed out")
        case .failed(let message):
            if let message, !message.isEmpty {
                showNotification("Java service failed to start: %@", arguments: [message])
            } else {
                showNotification("Java service failed to start")
            }
        }
    }
}
