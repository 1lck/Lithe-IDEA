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
        let task = Task { @MainActor [weak self, weak fallbackDocument, weak owner] in
            guard let owner else { return }
            guard let self else { return }
            defer {
                owner.task = nil
            }
            do {
                let sessions = try await self.languageSessionsForWorkspaceMaintenance()
                guard self.ownsJavaLanguageServerPreparation(
                    workspaceURL: normalizedRoot,
                    operationID: operationID
                ) else { return }
                sessions.recordLanguageServerLog(
                    providerID: "java",
                    operationID: operationID,
                    level: .info,
                    message: "Bundled JDK preparation started",
                    detail: nil
                )
                let preparation = await self.services.projectRuntimeService
                    .prepareJavaLanguageServerRuntime()
                guard !Task.isCancelled,
                      self.ownsJavaLanguageServerPreparation(
                        workspaceURL: normalizedRoot,
                        operationID: operationID
                      ) else { return }
                switch preparation {
                case .unprepared:
                    return
                case .failed(let message):
                    sessions.recordLanguageServerLog(
                        providerID: "java",
                        operationID: operationID,
                        level: .error,
                        message: "Bundled JDK preparation failed",
                        detail: message
                    )
                    self.failJavaLanguageServerPreparation(
                        workspaceURL: normalizedRoot,
                        operationID: operationID,
                        failure: .failed(message: message)
                    )
                    return
                case .ready(let executableURL):
                    sessions.recordLanguageServerLog(
                        providerID: "java",
                        operationID: operationID,
                        level: .info,
                        message: "Bundled JDK preparation succeeded",
                        detail: executableURL.path
                    )
                }
                let startedOperationID = try sessions.startLanguageServer(
                    providerID: "java",
                    rootURL: normalizedRoot,
                    operationID: operationID
                )
                guard self.ownsJavaLanguageServerPreparation(
                    workspaceURL: normalizedRoot,
                    operationID: operationID
                ) else { return }
                if startedOperationID != operationID {
                    owner.operationID = startedOperationID
                    if let currentState = sessions.languageServerStates["java"] {
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
            } catch {
                guard self.ownsJavaLanguageServerPreparation(
                    workspaceURL: normalizedRoot,
                    operationID: operationID
                ) else { return }
                self.languageToolingSessionsIfActive?.recordLanguageServerLog(
                    providerID: "java",
                    operationID: operationID,
                    level: .error,
                    message: "Java workspace preparation failed",
                    detail: error.localizedDescription
                )
                let sessionFailure = (error as? LanguageServerSessionStartError)?.failure
                self.failJavaLanguageServerPreparation(
                    workspaceURL: normalizedRoot,
                    operationID: operationID,
                    failure: sessionFailure?.isTimedOut == true
                        ? .timedOut(message: error.localizedDescription)
                        : .failed(message: error.localizedDescription)
                )
            }
        }
        owner.task = task
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
        guard let operationID,
              javaFeature.languageServerOperationID == operationID,
              let workspaceURL else { return }
        switch state {
        case .ready:
            javaFeature.markLanguageServerReady(
                workspaceURL: workspaceURL.standardizedFileURL,
                operationID: operationID
            )
            showNotification(String(localized: "Java service is ready"))
        case .failed(let failure):
            failJavaLanguageServerPreparation(
                workspaceURL: workspaceURL,
                operationID: operationID,
                failure: failure.isTimedOut
                    ? .timedOut(message: failure.message ?? "JDTLS failed to start.")
                    : .failed(message: failure.message ?? "JDTLS failed to start.")
            )
        case .startingProcess, .initializing, .stopping, .stopped:
            break
        }
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
        guard let workspaceURL,
              let policy = services.javaMavenOperations.javaWorkspacePolicy(
                at: workspaceURL,
                files: projectFiles,
                changedFiles: changes.map(\.fileURL)
              ) else { return }
        let changeKinds = Dictionary(
            uniqueKeysWithValues: changes.map { ($0.fileURL.standardizedFileURL, $0.kind) }
        )
        let openJavaURLs = Set(openDocuments.compactMap { document in
            document.url.pathExtension.lowercased() == "java"
                ? document.url.standardizedFileURL
                : nil
        })
        let languageServerChanges = policy.changes.compactMap { change
            -> LanguageServerWorkspaceFileChange? in
            guard change.kind == .source || change.kind == .buildConfiguration else {
                return nil
            }
            let url = change.url.standardizedFileURL
            guard !openJavaURLs.contains(url), let kind = changeKinds[url] else { return nil }
            let languageServerKind: LanguageServerWorkspaceFileChangeKind = switch kind {
            case .created: .created
            case .changed: .changed
            case .deleted: .deleted
            }
            return LanguageServerWorkspaceFileChange(
                fileURL: url,
                kind: languageServerKind
            )
        }
        guard !languageServerChanges.isEmpty else { return }
        do {
            try languageToolingSessionsIfActive?.notifyWorkspaceFilesChanged(
                providerID: "java",
                changes: languageServerChanges
            )
        } catch {
            languageToolingSessionsIfActive?.recordLanguageServerLog(
                providerID: "java",
                level: .error,
                message: "Java workspace change notification failed",
                detail: error.localizedDescription
            )
        }
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
