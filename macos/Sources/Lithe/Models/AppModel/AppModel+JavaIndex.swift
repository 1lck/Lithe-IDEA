import Combine
import Foundation
import LitheLanguageIntelligenceModule

extension AppModel {
    func rebuildJavaIndex() {
        guard let workspaceURL else {
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
                let sessions = try await languageSessionsForWorkspaceMaintenance()
                try sessions.rebuildWorkspaceState(providerID: "java", rootURL: workspaceURL)
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
        capability.sessions.configureMavenContextProvider { [weak self] descriptor, rootURL in
            guard descriptor.id == "java",
                  self?.workspaceURL?.standardizedFileURL == rootURL.standardizedFileURL else {
                return nil
            }
            return self?.mavenFeatureIfActive?.launchContext
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

    func languageSessionsForWorkspaceMaintenance() async throws
        -> LanguageToolingSessionManager
    {
        try await languageIntelligenceModuleCoordinator.sessionsForMaintenance(
            current: languageToolingSessionsIfActive
        )
    }
}
