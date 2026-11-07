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

    /// Opens the editor-area "LSP Logs" tab on `providerID`. The status menu's
    /// bottom entry passes the first listed server.
    func showLanguageServerLogs(providerID: String) {
        guard let logs = languageServerLogsFeature else { return }
        logs.open(providerID: providerID)
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
        languageServerLogsFeature?.stop()
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
        // The host works through the bound capability, not the module state:
        // a plugin's language server extension activates this module as its
        // dependency without binding it here, so an active module can still
        // have no sessions. Binding it is what lets a restored document start
        // its server without waiting for the user to click the tab.
        if languageToolingSessionsIfActive == nil {
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
                do { try services.moduleRuntime.markIdle(moduleID) } catch { services.logSink?.emit(AppModuleTransitionFailed(error: error, module: moduleID.rawValue, stage: "idle")) }
            }
            return languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id)
        } catch {
            languageToolingFeature.markActivationFailed(providerID: descriptor.id, descriptor: descriptor, error: error)
            return false
        }
    }

    func handleWorkspaceFileChanges(_ changes: [WorkspaceFileChange]) {
        runFeatureIfActive?.markDependencyFilesChanged(changes)
        handleBuildSystemFileChanges(changes)
        handleVcsProviderFileChanges(changes)
        toolchainSettingsFeature.workspaceFilesChanged(changes)
    }
}
