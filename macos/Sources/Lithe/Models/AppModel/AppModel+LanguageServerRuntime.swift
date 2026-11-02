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

    var statusBarLanguageServers: [LSPStatusBarServer] {
        let snapshot = languageToolingFeature.serverRuntimeSnapshot
        return LSPControlCenterPresenter.statusBarServers(
            registrations: services.languageServerRegistrations?(languageProviderCatalog) ?? [],
            states: snapshot.states, infos: snapshot.infos,
            disabledProviderIDs: languageToolingFeature.disabledProviderIDs
        )
    }

    func showLanguageServerLogs(providerID: String) {
        languageToolingFeature.logs.providerID = providerID
        if !editorTabOrderFeature.contains(.languageLogs) { editorTabOrderFeature.moveToEnd(.languageLogs) }
        selectLanguageServerLogsTab()
    }

    func selectLanguageServerLogsTab() {
        guard editorTabOrderFeature.contains(.languageLogs) else { return }
        terminalPlacementFeature.activateDocument()
        mediaFeature.deactivate()
        editorTabOrderFeature.repositoryDiffSelected = false
        activeDocumentID = nil
        editorNavigationTarget = nil
        editorTabOrderFeature.focus(.languageLogs)
    }

    func closeLanguageServerLogsTab() {
        let order = editorTabOrderFeature
        let wasFocused = order.focusedItem == .languageLogs
        order.remove(.languageLogs)
        if wasFocused, let fallback = order.focusedItem ?? order.items.last { selectEditorTab(fallback) }
    }

    @discardableResult
    func activateCurrentDocumentLanguageServerIfAvailable() -> Bool {
        guard let activeDocument else { return false }
        return activateLanguageServerIfAvailable(for: activeDocument)
    }

    @discardableResult
    func activateLanguageServerIfAvailable(for document: EditorDocument) -> Bool {
        guard !workspaceFeature.isIndexExcluded(document.url) else { return false }
        guard let identity = currentWorkspaceIdentity,
              let descriptor = languageProviderCatalog.provider(for: document.url) else { return false }
        let workspaceURL = identity.url
        let activationToken = languageToolingFeature.activationToken(providerID: descriptor.id)
        guard !languageToolingFeature.isDisabled(descriptor.id) else {
            languageToolingSessionsIfActive?.recordLanguageServerLog(
                providerID: descriptor.id,
                level: .info,
                message: L10n.string("Language server activation skipped"),
                detail: L10n.string("Disabled in this workspace")
            )
            return false
        }
        if isModuleRuntimeShuttingDown {
            Task { @MainActor [weak self, weak document] in
                guard let self else { return }
                await self.awaitModuleRuntimeShutdown()
                guard let document, !Task.isCancelled, self.isCurrentWorkspace(identity),
                      self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                      self.openDocuments.contains(where: { $0 === document }) else { return }
                _ = self.activateLanguageServerIfAvailable(for: document)
            }
            return false
        }
        if descriptor.id == "java" {
            switch prepareJavaLanguageServerRuntimeIfNeeded(for: document) {
            case .ready: break
            case .preparing: return false
            }
        }
        if let ownership = services.pluginCatalog.languageSupport(for: document.url),
           let moduleID = ownership.declaration.languageServerModuleID {
            let support = ownership.declaration
            // Static plugin metadata may exist before a native plugin is loaded.
            // Only a registered and enabled module may enter LSP activation.
            guard let snapshot = try? services.moduleRuntime.snapshot(for: moduleID),
                  snapshot.state != .disabled else {
                return false
            }
            let capabilityID = ModuleCapabilityID.languageServerExtension(support.id)
            if services.moduleRuntime.capability(capabilityID) == nil {
                Task { [weak self, weak document] in
                    guard let self, let document else { return }
                    do {
                        await self.awaitModuleRuntimeShutdown()
                        guard !Task.isCancelled, self.isCurrentWorkspace(identity),
                              self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                              self.openDocuments.contains(where: { $0 === document }) else { return }
                        _ = try await self.services.moduleRuntime.activateCapability(capabilityID)
                        guard self.isCurrentWorkspace(identity), !Task.isCancelled,
                              self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                              self.openDocuments.contains(where: { $0 === document }) else { return }
                        _ = self.activateLanguageServerIfAvailable(for: document)
                    } catch {
                        // Only an activation that is still wanted may report a failure.
                        guard self.isCurrentWorkspace(identity),
                              self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                              self.openDocuments.contains(where: { $0 === document }) else { return }
                        self.languageToolingFeature.markActivationFailed(
                            providerID: descriptor.id,
                            descriptor: descriptor,
                            error: error
                        )
                    }
                }
                return false
            }
            if let provider = services.moduleRuntime.capability(capabilityID)
                    as? any LanguageServerExtensionProviding,
               provider.lifecycle.isRetired {
                // The module is being stopped; its capability is still
                // published until the stop completes.
                return false
            }
            if let provider = services.moduleRuntime.capability(capabilityID)
                    as? any LanguageServerExtensionProviding,
               let sessions = languageToolingSessionsIfActive,
               !sessions.registerLanguageServerExtension(provider, support: support) {
                languageToolingFeature.markActivationFailed(
                    providerID: descriptor.id,
                    descriptor: descriptor,
                    error: LanguageExtensionRegistrationError.invalidLanguageServerProvider(
                        support.displayName
                    )
                )
                return false
            }
            // A plugin enabled after launch registers its server after the
            // startup probe ran, so probe it now instead of reporting the
            // executable as missing before any check happened.
            if let sessions = languageToolingSessionsIfActive,
               let tools = languageServerToolsIfActive,
               let registered = sessions.languageServerExtensionDescriptor(languageID: support.id),
               tools.needsCandidateValidation(for: registered) {
                Task { [weak self, weak document] in
                    await tools.refreshCandidates(for: registered)
                    guard let self, let document, self.isCurrentWorkspace(identity), !Task.isCancelled,
                          self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                          self.openDocuments.contains(where: { $0 === document }) else { return }
                    _ = self.activateLanguageServerIfAvailable(for: document)
                }
                return false
            }
            registerLanguageDependencySourceIfAvailable(support: support)
        }
        if let snapshot = try? services.moduleRuntime.snapshot(for: .languageIntelligence),
           snapshot.state != .active,
           snapshot.state != .idle {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.languageIntelligenceModuleCoordinator.activate()
                    guard self.isCurrentWorkspace(identity), !Task.isCancelled,
                          self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                          self.openDocuments.contains(where: { $0 === document }) else { return }
                    _ = self.activateLanguageServerIfAvailable(for: document)
                } catch {
                    guard self.isCurrentWorkspace(identity),
                          self.languageToolingFeature.activationToken(providerID: descriptor.id) == activationToken,
                          self.openDocuments.contains(where: { $0 === document }) else { return }
                    self.languageToolingFeature.markActivationFailed(
                        providerID: descriptor.id,
                        descriptor: descriptor,
                        error: error
                    )
                }
            }
            return false
        }
        do {
            guard let languageToolingSessions = languageToolingSessionsIfActive else { return false }
            try languageToolingSessions.synchronizeLanguageServer(
                for: document.url,
                text: document.text,
                rootURL: workspaceURL,
                changes: document.takePendingLanguageServerChanges()
            )
            languageToolingFeature.markActivationSucceeded(providerID: descriptor.id)
            if let moduleID = services.pluginCatalog.languageSupport(for: document.url)?
                    .declaration.languageServerModuleID {
                // A successful sync is the plugin LSP's latest activity. The
                // idle policy can stop it after the user leaves the document
                // untouched, while subsequent edits refresh this timestamp.
                try? services.moduleRuntime.markIdle(moduleID)
            }
            return languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id)
        } catch {
            languageToolingFeature.markActivationFailed(providerID: descriptor.id, descriptor: descriptor, error: error)
            return false
        }
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
        toolchainSettingsFeature.workspaceFilesChanged(changes)
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
