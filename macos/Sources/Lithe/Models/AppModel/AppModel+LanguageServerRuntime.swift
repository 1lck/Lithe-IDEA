import Foundation
import LitheCoreContracts

@MainActor
extension AppModel {
    func chooseLanguageServerExecutable(providerName: String) -> URL? {
        platformUI.chooseFile(
            title: settings.language == .simplifiedChinese
                ? "选择 \(providerName) 语言服务器"
                : "Choose \(providerName) language server",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
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
        if enabled {
            languageToolingFeature.setEnabled(true, providerID: providerID)
        } else {
            languageToolingFeature.setEnabled(false, providerID: providerID)
        }
    }

    func disableLanguageServerForCurrentWorkspace(providerID: String) {
        languageToolingFeature.setEnabled(false, providerID: providerID)
    }

    func prepareJavaLanguageServerRuntimeIfNeeded(
        for document: EditorDocument
    ) -> JavaLanguageServerActivationReadiness {
        if services.projectRuntimeService.isJavaLanguageServerRuntimePrepared() {
            return .ready
        }
        guard case .idle = javaFeature.languageServerWorkspaceState,
              let workspaceURL else { return .preparing }
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
                return try await self.languageSessionsForWorkspaceMaintenance()
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
        if case .preparing(let owner) = javaFeature.languageServerWorkspaceState {
            languageToolingSessionsIfActive?.recordLanguageServerLog(
                providerID: "java",
                operationID: owner.operationID,
                level: .warning,
                message: "Java workspace preparation cancelled",
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
        let currentWorkspaceURL = workspaceURL
        javaLanguageServerPreparationCoordinator.handleSessionState(
            state,
            operationID: operationID,
            javaFeature: javaFeature,
            workspaceURL: workspaceURL,
            onReady: { [weak self] in
                self?.showNotification(String(localized: "Java service is ready"))
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
        showNotification(String(localized: "Java service is preparing"))
    }

    func handleJavaWorkspaceFileChanges(_ changes: [WorkspaceFileChange]) {
        guard let workspaceURL else { return }
        javaLanguageServerPreparationCoordinator.notifyWorkspaceFileChanges(
            changes,
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

    private func ownsJavaLanguageServerPreparation(
        workspaceURL: URL,
        operationID: UUID
    ) -> Bool {
        javaFeature.ownsLanguageServerPreparation(
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
            showNotification(String(localized: "Java service preparation timed out"))
        case .failed(let message):
            if let message, !message.isEmpty {
                showNotification(String(
                    format: String(localized: "Java service failed to start: %@"),
                    message
                ))
            } else {
                showNotification(String(localized: "Java service failed to start"))
            }
        }
    }
}
