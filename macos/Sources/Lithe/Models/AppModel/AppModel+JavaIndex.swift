import Combine
import Foundation
import LitheLanguageIntelligenceModule
import LitheModuleAPI

extension AppModel {
    func rebuildJavaIndex() {
        guard let identity = currentWorkspaceIdentity else {
            showNotification(
                settings.language == .simplifiedChinese
                    ? "请先打开一个项目"
                    : "Open a project before rebuilding the Java index."
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sessions = try await languageSessionsForWorkspaceMaintenance(for: identity)
                try sessions.rebuildWorkspaceState(providerID: "java", rootURL: identity.url)
                cancelJavaLanguageServerPreparation()
                languageIntelligenceModuleCoordinator.resetWorkspaceState(languageToolingFeature)
                showNotification(
                    settings.language == .simplifiedChinese
                        ? "Java 索引已清除，重新打开 Java 文件时将自动重建"
                        : "Java index cleared. Reopen a Java file to rebuild."
                )
            } catch {
                let prefix = settings.language == .simplifiedChinese
                    ? "清除 Java 索引失败"
                    : "Failed to clear the Java index"
                showNotification("\(prefix): \(error.localizedDescription)")
            }
        }
    }

    func bindLanguageIntelligenceCapability(_ capability: LanguageIntelligenceCapability) {
        languageToolingFeature.bindProjectPreparation(capability.sessions)
        cacheModuleCapability(
            capability,
            id: .languageIntelligence,
            moduleID: .languageIntelligence
        )
        observeModuleFeature(
            .languageIntelligence,
            observation: capability.sessions.objectWillChange.sink { [weak self] _ in
                self?.handleLanguageSessionChange()
            }
        )
        capability.sessions.configureJavaLanguageImportProvider { [weak self] _, rootURL in
            guard let self else { throw CancellationError() }
            return try self.javaLanguageImportConfiguration(rootURL: rootURL)
        }
        capability.tools.onCandidatesChanged = { [weak self] providerID in
            guard let self,
                  self.languageToolingFeature.shouldRetryCandidate(providerID: providerID),
                  let document = self.activeDocument,
                  self.languageProviderCatalog.provider(for: document.url)?.id == providerID else {
                return
            }
            _ = self.activateLanguageServerIfAvailable(for: document)
        }
        capability.sessions.onLanguageServerStateChange = { [weak self] providerID, state, operationID in
            guard providerID == "java" else { return }
            self?.handleJavaLanguageServerState(state, operationID: operationID)
        }
    }

    func languageSessionsForWorkspaceMaintenance(for expectedIdentity: WorkspaceIdentity? = nil) async throws
        -> LanguageToolingSessionManager
    {
        guard let identity = expectedIdentity ?? currentWorkspaceIdentity,
              isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
        let sessions = try await languageIntelligenceModuleCoordinator.sessionsForMaintenance(
            current: languageToolingSessionsIfActive
        )
        try Task.checkCancellation()
        guard isCurrentWorkspace(identity) else { throw CancellationError() }
        await registerPluginLanguageServers(in: sessions)
        try Task.checkCancellation()
        guard isCurrentWorkspace(identity) else { throw CancellationError() }
        try await prepareBuildLanguageImport()
        try Task.checkCancellation()
        guard isCurrentWorkspace(identity) else { throw CancellationError() }
        return sessions
    }

    /// Workspace maintenance starts a language server without an open
    /// document, so the document path has not registered the servers that
    /// plugins provide yet. Without this the session manager only knows the
    /// catalog entry of the language, which has no launch of its own.
    private func registerPluginLanguageServers(in sessions: LanguageToolingSessionManager) async {
        let supports = services.pluginCatalog.languageSupports.values
            .map(\.declaration)
            .sorted { $0.id < $1.id }
        let identity = currentWorkspaceIdentity
        for support in supports {
            guard !Task.isCancelled, currentWorkspaceIdentity == identity else { return }
            guard let moduleID = support.languageServerModuleID,
                  !languageToolingFeature.isDisabled(support.id),
                  let snapshot = try? services.moduleRuntime.snapshot(for: moduleID),
                  snapshot.state != .disabled else { continue }
            let capabilityID = ModuleCapabilityID.languageServerExtension(support.id)
            let capability: AnyObject?
            if let active = services.moduleRuntime.capability(capabilityID) {
                capability = active
            } else {
                // A module that cannot activate is reported when its server
                // is started; it must not block the other languages.
                capability = try? await services.moduleRuntime.activateCapability(capabilityID)
            }
            guard !Task.isCancelled, currentWorkspaceIdentity == identity else { return }
            guard let provider = capability as? any LanguageServerExtensionProviding,
                  sessions.registerLanguageServerExtension(provider, support: support) else { continue }
            if let tools = languageServerToolsIfActive,
               let registered = sessions.languageServerExtensionDescriptor(languageID: support.id),
               tools.needsCandidateValidation(for: registered) {
                await tools.refreshCandidates(for: registered)
            }
        }
    }
}
